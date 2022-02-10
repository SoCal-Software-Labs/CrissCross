defmodule CrissCross.InternalRedis do
  require Logger

  alias CrissCross.Utils
  alias CrissCross.ConnectionCache

  @max_peer_tries 3
  @read_commands [
    "GET_MULTI_BIN",
    "GET_MULTI",
    "FETCH",
    "FETCH_BIN",
    "HAS_KEY",
    "HAS_KEY_BIN",
    "SQL",
    "SQL_JSON",
    "CLONE"
  ]

  @doc """
  {:ok, rsa_priv_key} = ExPublicKey.generate_key()
  {:ok, rsa_pub_key} = ExPublicKey.public_key_from_private_key(rsa_priv_key)
  {:ok, pem_string_private} = ExPublicKey.pem_encode(rsa_priv_key)
  {:ok, pem_string_public} = ExPublicKey.pem_encode(rsa_pub_key)

  {:ok, conn} = Redix.start_link(host: "localhost", port: 2004)
  cluster = "CsFD25YQcZ6N179edKvhRkV9Nv75gjL6MwV16z5frniQ" |> CrissCross.decode_human!()
  loc = <<102, 28, 56, 250, 109, 167, 206, 238, 224, 114, 17, 192, 226, 64, 229, 236,
  177, 166, 81, 213, 84, 152, 13, 71, 143, 30, 53, 56, 185, 212, 210, 42>>

  {:ok, name} = Redix.command(conn, ["POINTERSET", "122", cluster, pem_string_private, "1000"])

  Redix.command(conn, ["POINTERLOOKUP", cluster, name, "0"])

  Redix.command(conn, ["VARSET", "boom", loc])
  Redix.command(conn, ["VARWITH", "boom", "REMOTE", cluster, "2", "SQL_JSON", "SELECT * FROM Glue WHERE id > 100;"])
  Redix.command(conn, ["VARWITH", "boom", "REMOTE", cluster, "2", "SQL_JSON", loc, "SELECT * FROM Glue WHERE id > 100;"])


  {:ok, loc} = Redix.command(conn, ["PUT_MULTI", "", :erlang.term_to_binary("hello"), :erlang.term_to_binary("world")])
  Redix.command(conn, ["GET_MULTI", loc, :erlang.term_to_binary("hello")])

  Redix.command(conn, ["WOW", "cool"])

  {:ok, conn} = Redix.start_link(host: "localhost", port: 35002)
  {:ok, [loc | _]} = Redix.command(conn, ["SQL_JSON", "", "DROP TABLE IF EXISTS Glue;", "CREATE TABLE Glue (id INTEGER);", "INSERT INTO Glue VALUES (100);", "INSERT INTO Glue VALUES (200);", "SELECT * FROM Glue WHERE id > 100;"])
  cluster = "CsFD25YQcZ6N179edKvhRkV9Nv75gjL6MwV16z5frniQ" |> CrissCross.decode_human!()
  Redix.command(conn, ["ANNOUNCE", cluster, loc, "60000000"])
  Redix.command(conn, ["HAS_ANNOUNCED", cluster, loc])



  cluster = "CsFD25YQcZ6N179edKvhRkV9Nv75gjL6MwV16z5frniQ" |> CrissCross.decode_human!()

  loc = <<103, 109, 208, 95, 120, 253, 34, 104, 253, 201, 74, 201, 73, 13, 215, 87,
     254, 86, 201, 243, 205, 191, 55, 75, 117, 153, 41, 103, 110, 85, 191,
     214>>
  CrissCross.announce_have_tree(cluster, loc, 35001)
  """

  def accept(port, external_port, local_redis_opts) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, active: true, reuseaddr: true])
    Logger.info("Accepting connections on port #{port}")
    {:ok, redis_conn} = Redix.start_link(local_redis_opts)

    make_store = fn hash -> CrissCross.Store.Local.create(redis_conn, hash) end

    loop_acceptor(socket, %{
      external_port: external_port,
      redis_conn: redis_conn,
      make_store: make_store
    })
  end

  defp loop_acceptor(socket, state) do
    {:ok, client} = :gen_tcp.accept(socket)

    {:ok, pid} =
      Task.Supervisor.start_child(CrissCross.TaskSupervisor, fn ->
        serve(client, %{continuation: nil}, state)
      end)

    :ok = :gen_tcp.controlling_process(client, pid)

    loop_acceptor(socket, state)
  end

  defp serve(socket, %{continuation: nil}, state) do
    receive do
      {:tcp, ^socket, data} -> handle_parse(socket, Redix.Protocol.parse(data), state)
      {:tcp_closed, ^socket} -> :ok
    end
  end

  defp serve(socket, %{continuation: fun}, state) do
    receive do
      {:tcp, ^socket, data} -> handle_parse(socket, fun.(data), state)
      {:tcp_closed, ^socket} -> :ok
    end
  end

  defp handle_parse(socket, {:continuation, fun}, state) do
    serve(socket, %{continuation: fun}, state)
  end

  defp handle_parse(socket, {:ok, req, left_over}, state) do
    resp = handle(req, state)
    # try do

    # rescue
    #   e in ArgumentError -> "-Invalid BERT encoding\r\n"
    # end

    :gen_tcp.send(socket, resp)

    case left_over do
      "" -> serve(socket, %{continuation: nil}, state)
      _ -> handle_parse(socket, Redix.Protocol.parse(left_over), state)
    end
  end

  def do_remote(cluster, num, command, tree, args, state, use_local) do
    case get_conns(cluster, command, num, tree, args, state, []) do
      {:ok, conns} ->
        new_make_store = fn hash ->
          {:ok, store} =
            if use_local do
              state.make_store.(hash)
            else
              CubDB.Store.MerkleStore.create()
            end

          CrissCross.Store.CachedRPC.create(conns, hash, store)
        end

        handle([command, tree | args], %{state | make_store: new_make_store})

      {:error, msg} ->
        "-#{msg}\r\n"
    end
  end

  def get_conns(_cluster, _command, _num, _tree, _args, _state, skip_nodes)
      when length(skip_nodes) > @max_peer_tries do
    {:error, "Tried #{@max_peer_tries} peers"}
  end

  def get_conns(cluster, command, num, tree, args, state, skip_nodes) do
    peers = CrissCross.find_peers_for_header(cluster, tree, num, skip_nodes)

    case peers do
      [peer | _] = peers ->
        ret =
          Enum.reduce_while(peers, [], fn peer, conns ->
            case ConnectionCache.get_conn(cluster, peer.ip, peer.port) do
              {:ok, conn} ->
                {:cont, [conn | conns]}

              {:error, error} ->
                Logger.error("Could not connect to peer #{inspect(peer)}")
                {:halt, {:error, peer}}
            end
          end)

        case ret do
          conns when is_list(conns) ->
            {:ok, conns}

          {:error, peer} ->
            get_conns(cluster, command, num, tree, args, state, [peer | skip_nodes])
        end

      [] ->
        "-No available peers\r\n"
    end
  end

  def handle(["REMOTENOLOCAL", cluster, num_remotes, command, tree | args], state)
      when command in @read_commands do
    case Integer.parse(num_remotes) do
      {num, _} when num > 0 ->
        do_remote(cluster, num, command, tree, args, state, false)

      _ ->
        "-Invalid number of peers\r\n"
    end
  end

  def handle(["REMOTE", cluster, num_remotes, command, tree | args], state)
      when command in @read_commands do
    case Integer.parse(num_remotes) do
      {num, _} when num > 0 ->
        do_remote(cluster, num, command, tree, args, state, true)

      _ ->
        "-Invalid number of peers\r\n"
    end
  end

  def handle(["VARWITH", local_var, command | args], %{redis_conn: redis_conn} = state) do
    case Redix.command(redis_conn, ["GET", Enum.join(["vars", local_var], "-")]) do
      {:ok, val} when is_binary(val) ->
        if command in ["REMOTE", "REMOTENOLOCAL"] do
          case args do
            [cluster, remotes, subcommand | rest] ->
              handle([command, cluster, remotes, subcommand, val | rest], state)

            _ ->
              "-#{command} use with VARWITH malformed\r\n"
          end
        else
          handle([command, val | args], state)
        end

      _ ->
        "-Invalid VAR\r\n"
    end
  end

  def handle(["VARSET", local_var, val], %{redis_conn: redis_conn} = state) do
    case Redix.command(redis_conn, ["SET", Enum.join(["vars", local_var], "-"), val]) do
      {:ok, _val} ->
        Utils.encode_redis_string("OK")

      {:error, e} ->
        "-error #{}\r\n"
    end
  end

  def handle(["SELECT", tree, query], %{make_store: make_store}) do
  end

  def handle(["GET_MULTI_BIN", tree, loc | locs], %{make_store: make_store}) do
    loc_terms = [loc | locs]
    {:ok, store} = make_store.(clean_tree(tree))
    res = CrissCross.get_multi(store, loc_terms)

    Enum.flat_map([loc | locs], fn l ->
      case Map.get(res, l) do
        nil -> []
        val -> [l, val]
      end
    end)
    |> Utils.encode_redis_list()
  end

  def handle(["GET_MULTI", tree, loc | locs], %{make_store: make_store}) do
    loc_terms = [loc | locs] |> Enum.map(&Utils.deserialize_bert/1)
    {:ok, store} = make_store.(clean_tree(tree))
    res = CrissCross.get_multi(store, loc_terms)

    Enum.flat_map(loc_terms, fn l ->
      case Map.get(res, l) do
        nil -> []
        val -> [l, val |> Utils.serialize_bert()]
      end
    end)
    |> Utils.encode_redis_list()
  end

  def handle(["CLONE", tree], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_tree(tree))
    res = CrissCross.clone(store, make_store)

    case res do
      :ok -> Utils.encode_redis_string("OK")
      {:error, e} -> "-#{inspect(e)}\r\n"
    end
  end

  def handle(["FETCH", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_tree(tree))

    case CrissCross.fetch(store, loc |> Utils.deserialize_bert()) do
      {:ok, value} -> Utils.encode_redis_string(value |> Utils.serialize_bert())
      :error -> "$-1\r\n"
    end
  end

  def handle(["FETCH_BIN", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_tree(tree))

    case CrissCross.fetch(store, loc) do
      {:ok, value} -> Utils.encode_redis_string(value)
      :error -> "$-1\r\n"
    end
  end

  def handle(["HAS_KEY", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_tree(tree))

    case CrissCross.has_key?(store, loc |> Utils.deserialize_bert()) do
      true -> Utils.encode_redis_integer(1)
      false -> Utils.encode_redis_integer(0)
    end
  end

  def handle(["HAS_KEY_BIN", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_tree(tree))

    case CrissCross.has_key?(store, loc) do
      true -> Utils.encode_redis_integer(1)
      false -> Utils.encode_redis_integer(0)
    end
  end

  def handle(["PUT_MULTI", tree, key, value | kvs], %{make_store: make_store})
      when rem(length(kvs), 2) == 0 do
    terms =
      [key, value | kvs]
      |> Enum.chunk_every(2)
      |> Enum.map(fn [k, v] ->
        {Utils.deserialize_bert(k), Utils.deserialize_bert(v)}
      end)

    {:ok, store} = make_store.(clean_tree(tree))
    location = CrissCross.put_multi(store, terms)
    Utils.encode_redis_string(location)
  end

  def handle(["PUT_MULTI_BIN", tree, key, value | kvs], %{make_store: make_store})
      when rem(length(kvs), 2) == 0 do
    terms =
      [key, value | kvs]
      |> Enum.chunk_every(2)
      |> Enum.map(fn [k, v] ->
        {k, v}
      end)

    {:ok, store} = make_store.(clean_tree(tree))
    location = CrissCross.put_multi(store, terms)
    Utils.encode_redis_string(location)
  end

  def handle(["DELETE_KEY", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_tree(tree))
    location = CrissCross.delete_key(store, Utils.deserialize_bert(loc))
    Utils.encode_redis_string(location)
  end

  def handle(["DELETE_KEY_BIN", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_tree(tree))
    location = CrissCross.delete_key(store, loc)
    Utils.encode_redis_string(location)
  end

  def handle(["SQL", tree, statement | rest], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_tree(tree))
    {location, return} = CrissCross.sql(store, make_store, [statement | rest])
    Utils.encode_redis_list([location] ++ Enum.map(return, &Utils.serialize_bert/1))
  end

  def handle(["SQL_JSON", tree, statement | rest], %{
        external_port: external_port,
        make_store: make_store
      }) do
    {:ok, store} = make_store.(clean_tree(tree))
    {location, return} = CrissCross.sql(store, make_store, [statement | rest])
    return = return |> Enum.map(fn {status, v} -> [status, v] end)
    Utils.encode_redis_list([location] ++ Enum.map(return, &Jason.encode!/1))
  end

  def handle(["ANNOUNCE", cluster, tree, ttl], %{
        external_port: external_port,
        make_store: make_store
      }) do
    {:ok, store} = make_store.(clean_tree(tree))

    case Integer.parse(ttl) do
      {num, _} ->
        :ok = CrissCross.announce(store, cluster, tree, external_port, num)
        Utils.encode_redis_string("OK")

      _ ->
        "-Invalid TTL Integer\r\n"
    end
  end

  def handle(["HAS_ANNOUNCED", cluster, tree], %{
        external_port: external_port,
        make_store: make_store
      }) do
    {:ok, store} = make_store.(clean_tree(tree))

    case CrissCross.has_announced(store, cluster, tree) do
      true ->
        Utils.encode_redis_integer(1)

      _ ->
        Utils.encode_redis_integer(0)
    end
  end

  def handle(["POINTERLOOKUP", cluster, name, generation], _state) do
    case Integer.parse(generation) do
      {num, _} when num >= 0 ->
        case CrissCross.find_pointer(cluster, name, num) do
          name when is_binary(name) -> Utils.encode_redis_string(name)
          :timeout -> "$-1\r\n"
          :not_found -> "$-1\r\n"
          {:error, e} -> "-Error setting pointer #{inspect(e)}\r\n"
        end

      _ ->
        "-Invalid generation\r\n"
    end
  end

  def handle(["POINTERLOOKUP", cluster, name, generation], _state) do
    case Integer.parse(generation) do
      {num, _} when num >= 0 ->
        case CrissCross.find_pointer(cluster, name, num) do
          name when is_binary(name) -> Utils.encode_redis_string(name)
          :timeout -> "$-1\r\n"
          :not_found -> "$-1\r\n"
          {:error, e} -> "-Error setting pointer #{inspect(e)}\r\n"
        end

      _ ->
        "-Invalid generation\r\n"
    end
  end

  def handle(["POINTERSET", value, cluster, private_key_pem, ttl], _state) do
    case ExPublicKey.loads(private_key_pem) do
      {:ok, private_key} ->
        case Integer.parse(ttl) do
          {num, _} when num >= 0 ->
            case CrissCross.set_pointer(cluster, private_key, value, num) do
              {l, _} -> Utils.encode_redis_string(l)
              {:error, e} -> "-#{inspect(e)}\r\n"
            end

          _ ->
            "-Invalid generation\r\n"
        end

      _ ->
        "-Invalid private key\r\n"
    end
  end

  def handle(c, _) do
    Logger.error("Invalid command #{inspect(c)}")
    "-Invalid command\r\n"
  end

  def clean_tree("nil"), do: nil
  def clean_tree(""), do: nil
  def clean_tree(v), do: v
end
