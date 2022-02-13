defmodule CrissCross.InternalRedis do
  require Logger

  import CrissCross.Utils
  alias CrissCross.Utils.{MissingHashError, DecoderError}
  alias CubDB.Store
  alias CrissCross.Scanner
  alias CrissCross.ConnectionCache
  alias CrissCross.Store.CachedRPC
  alias CrissCrossDHT.Server.Utils, as: DHTUtils

  @max_peer_tries 3
  @read_commands [
    "GETMULTIBIN",
    "GETMULTI",
    "FETCH",
    "FETCHBIN",
    "HASKEY",
    "HASKEYBIN",
    "SQL",
    "SQLJSON",
    "ITERSTART",
    "CLONE",
    "BYTESWRITTEN"
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

  Redix.command(conn, ["REMOTE", cluster, "2", "SQLJSON", loc, "SELECT * FROM Glue WHERE id > 100;"])


  {:ok, name} = Redix.command(conn, ["POINTERSET", "122", cluster, pem_string_private, "1000"])

  Redix.command(conn, ["POINTERLOOKUP", cluster, name, "0"])

  Redix.command(conn, ["VARSET", "boom", loc])
  Redix.command(conn, ["VARWITH", "boom", "REMOTE", cluster, "2", "SQL_JSON", "SELECT * FROM Glue WHERE id > 100;"])
  Redix.command(conn, ["VARWITH", "boom", "REMOTE", cluster, "2", "SQL_JSON", loc, "SELECT * FROM Glue WHERE id > 100;"])


  {:ok, loc} = Redix.command(conn, ["PUT_MULTI", "", :erlang.term_to_binary("hello"), :erlang.term_to_binary("world")])
  Redix.command(conn, ["GET_MULTI", loc, :erlang.term_to_binary("hello")])

  Redix.command(conn, ["WOW", "cool"])

  {:ok, conn} = Redix.start_link(host: "localhost", port: 35002)
  {:ok, [loc | _]} = Redix.command(conn, ["SQLJSON", "", "DROP TABLE IF EXISTS Glue;", "CREATE TABLE Glue (id INTEGER);", "INSERT INTO Glue VALUES (100);", "INSERT INTO Glue VALUES (200);", "SELECT * FROM Glue WHERE id > 100;"])
  cluster = "CsFD25YQcZ6N179edKvhRkV9Nv75gjL6MwV16z5frniQ" |> CrissCross.decode_human!()
  Redix.command(conn, ["ANNOUNCE", cluster, loc, "60000000"])
  Redix.command(conn, ["HASANNOUNCED", cluster, loc])



  cluster = "CsFD25YQcZ6N179edKvhRkV9Nv75gjL6MwV16z5frniQ" |> CrissCross.decode_human!()

  loc = <<103, 109, 208, 95, 120, 253, 34, 104, 253, 201, 74, 201, 73, 13, 215, 87,
     254, 86, 201, 243, 205, 191, 55, 75, 117, 153, 41, 103, 110, 85, 191,
     214>>
  CrissCross.announce_have_tree(cluster, loc, 35001)
  """

  def accept(port, external_port, local_redis_opts, auth) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, active: true, reuseaddr: true])
    Logger.info("Accepting connections on port #{port}")
    {:ok, redis_conn} = Redix.start_link(local_redis_opts)

    make_store = fn hash -> CrissCross.Store.Local.create(redis_conn, hash, false) end

    loop_acceptor(socket, %{
      auth: auth,
      iterator: nil,
      authed: false,
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
    {resp, new_state} =
      case req do
        ["AUTH", _, _] ->
          handle_auth(req, state)

        _ ->
          try do
            handle(req, state)
          rescue
            e in DecoderError ->
              {"-Invalid BERT encoding\r\n", state}

            e in MissingHashError ->
              {"-Storage is missing value for hash #{e.message}\r\n", state}
          end
      end

    :gen_tcp.send(socket, resp)

    case left_over do
      "" -> serve(socket, %{continuation: nil}, new_state)
      _ -> handle_parse(socket, Redix.Protocol.parse(left_over), new_state)
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

          CachedRPC.create(conns, hash, store)
        end

        handle([command, tree | args], %{
          state
          | make_store: new_make_store
        })

      {:error, msg} ->
        {"-#{msg}\r\n", state}
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
          Stream.repeatedly(fn -> Enum.random(peers) end)
          |> Enum.take(num)
          |> Enum.reduce_while(peers, [], fn peer, conns ->
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
        {:error, "No available peers"}
    end
  end

  def handle_auth(["AUTH", _, _], %{auth: nil, authed: false} = state) do
    {"-AUTH not supported\r\n", state}
  end

  def handle_auth(["AUTH", username, password], %{auth: auth, authed: false} = state) do
    if auth == Enum.join([username, password], ":") do
      {"+OK\r\n", %{state | authed: true}}
    else
      {"-Invalid credentials\r\n", state}
    end
  end

  def handle_iter(["ITERSTART", tree], %{make_store: make_store} = state) do
    {:ok, store} = make_store.(clean_maybe(tree))
    btree = CubDB.Btree.new(store)
    {:ok, pid} = Scanner.start_link(btree, false, nil, nil)
    {"+OK\r\n", %{state | iterator: pid}}
  end

  def handle_iter(
        ["ITERSTART", tree, min_key, max_key, inc_min, inc_max, reverse],
        %{make_store: make_store} = state
      ) do
    mink =
      case clean_maybe(min_key) do
        nil -> nil
        k -> {deserialize_bert(k), clean_bool(inc_min)}
      end

    maxk =
      case clean_maybe(max_key) do
        nil -> nil
        k -> {deserialize_bert(k), clean_bool(inc_max)}
      end

    {:ok, store} = make_store.(clean_maybe(tree))
    btree = CubDB.Btree.new(store)
    {:ok, pid} = Scanner.start_link(btree, clean_bool(reverse), mink, maxk)
    {"+OK\r\n", %{state | iterator: pid}}
  end

  def handle_iter(["ITERNEXT"], %{iterator: pid} = state) when is_pid(pid) do
    case Scanner.next(pid) do
      {k, v} ->
        {encode_redis_list([serialize_bert(k), serialize_bert(v)]), state}

      :done ->
        {"+DONE\r\n", %{state | iterator: nil}}
    end
  end

  def handle_iter(["ITERSTOP"], %{iterator: pid} = state) when is_pid(pid) do
    GenServer.stop(pid)
    {"+OK\r\n", %{state | iterator: nil}}
  end

  def handle_iter(_, state) do
    {"-Not in Iterator\r\n", state}
  end

  def handle(_, %{auth: auth, authed: false} = state) when is_binary(auth) do
    {"-Not Authenticated\r\n", state}
  end

  def handle([command | rest], state) when command in ["ITERSTART", "ITERNEXT", "ITERSTOP"] do
    handle_iter([command | rest], state)
  end

  def handle(_, %{iterator: it} = state) when is_pid(it) do
    {"-Active Iterator\r\n", state}
  end

  def handle(["REMOTENOLOCAL", cluster, num_remotes, command, tree | args], state)
      when command in @read_commands do
    case Integer.parse(num_remotes) do
      {num, _} when num > 0 ->
        do_remote(cluster, num, command, tree, args, state, false)

      _ ->
        {"-Invalid number of peers\r\n", state}
    end
  end

  def handle(["REMOTE", cluster, num_remotes, command, tree | args], state)
      when command in @read_commands do
    case Integer.parse(num_remotes) do
      {num, _} when num > 0 ->
        do_remote(cluster, num, command, tree, args, state, true)

      _ ->
        {"-Invalid number of peers\r\n", state}
    end
  end

  def handle(["VARWITH", local_var, command | args], %{redis_conn: redis_conn} = state) do
    case Redix.command(redis_conn, ["GET", Enum.join(["vars", local_var], "-")]) do
      {:ok, val} when is_binary(val) ->
        if command in ["REMOTE", "REMOTENOLOCAL"] do
          case args do
            [cluster, remotes, subcommand | rest] ->
              {handle([command, cluster, remotes, subcommand, val | rest], state), state}

            _ ->
              "-#{command} use with VARWITH malformed\r\n"
          end
        else
          handle([command, val | args], state)
        end

      _ ->
        {"-Invalid VAR\r\n", state}
    end
  end

  def handle(["VARSET", local_var, val], %{redis_conn: redis_conn} = state) do
    case Redix.command(redis_conn, ["SET", Enum.join(["vars", local_var], "-"), val]) do
      {:ok, _val} ->
        {"+OK\r\n", state}

      {:error, e} ->
        {"-error #{inspect(e)}\r\n", state}
    end
  end

  def handle(c, %{redis_conn: redis_conn} = state) do
    {handle_stateless(c, state), state}
  end

  def handle_stateless(["VARGET", local_var], %{redis_conn: redis_conn} = state) do
    case Redix.command(redis_conn, ["GET", Enum.join(["vars", local_var], "-")]) do
      {:ok, val} when is_binary(val) ->
        encode_redis_string(val)

      _ ->
        "-Invalid VAR\r\n"
    end
  end

  def handle_stateless(["GETMULTIBIN", tree, loc | locs], %{make_store: make_store}) do
    loc_terms = [loc | locs]
    {:ok, store} = make_store.(clean_maybe(tree))
    res = CrissCross.get_multi(store, loc_terms)
    Store.close(store)

    Enum.flat_map([loc | locs], fn l ->
      case Map.get(res, l) do
        nil -> []
        val -> [l, val]
      end
    end)
    |> encode_redis_list()
  end

  def handle_stateless(["BYTESWRITTEN", tree], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree))
    {{loc, _}, _} = Store.get_latest_header(store)
    Store.close(store)
    encode_redis_integer(loc)
  end

  def handle_stateless(["GETMULTI", tree, loc | locs], %{make_store: make_store}) do
    loc_terms = [loc | locs] |> Enum.map(&deserialize_bert/1)
    {:ok, store} = make_store.(clean_maybe(tree))
    res = CrissCross.get_multi(store, loc_terms)
    Store.close(store)

    Enum.flat_map(loc_terms, fn l ->
      case Map.get(res, l) do
        nil -> []
        val -> [l |> serialize_bert(), val |> serialize_bert()]
      end
    end)
    |> encode_redis_list()
  end

  def handle_stateless(["CLONE", tree], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree))
    res = CrissCross.clone(store, make_store)
    Store.close(store)

    case res do
      :ok -> "+OK\r\n"
      {:error, e} -> "-#{inspect(e)}\r\n"
    end
  end

  def handle_stateless(["FETCH", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree))

    r = CrissCross.fetch(store, loc |> deserialize_bert())
    Store.close(store)

    case r do
      {:ok, value} -> encode_redis_string(value |> serialize_bert())
      :error -> "$-1\r\n"
    end
  end

  def handle_stateless(["FETCHBIN", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree))
    r = CrissCross.fetch(store, loc)
    Store.close(store)

    case r do
      {:ok, value} -> encode_redis_string(value)
      :error -> "$-1\r\n"
    end
  end

  def handle_stateless(["HASKEY", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree))
    r = CrissCross.has_key?(store, loc |> deserialize_bert())
    Store.close(store)

    case r do
      true -> encode_redis_integer(1)
      false -> encode_redis_integer(0)
    end
  end

  def handle_stateless(["HASKEYBIN", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree))
    r = CrissCross.has_key?(store, loc)
    Store.close(store)

    case r do
      true -> encode_redis_integer(1)
      false -> encode_redis_integer(0)
    end
  end

  def handle_stateless(["PUTMULTI", tree, key, value | kvs], %{make_store: make_store})
      when rem(length(kvs), 2) == 0 do
    terms =
      [key, value | kvs]
      |> Enum.chunk_every(2)
      |> Enum.map(fn [k, v] ->
        {deserialize_bert(k), deserialize_bert(v)}
      end)

    {:ok, store} = make_store.(clean_maybe(tree))
    location = CrissCross.put_multi(store, terms)
    Store.close(store)
    encode_redis_string(location)
  end

  def handle_stateless(["PUTMULTIBIN", tree, key, value | kvs], %{make_store: make_store})
      when rem(length(kvs), 2) == 0 do
    terms =
      [key, value | kvs]
      |> Enum.chunk_every(2)
      |> Enum.map(fn [k, v] ->
        {k, v}
      end)

    {:ok, store} = make_store.(clean_maybe(tree))
    location = CrissCross.put_multi(store, terms)
    Store.close(store)
    encode_redis_string(location)
  end

  def handle_stateless(["DELMULTIKEY", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree))
    location = CrissCross.delete_key(store, deserialize_bert(loc))
    Store.close(store)
    encode_redis_string(location)
  end

  def handle_stateless(["DELMULTIBIN", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree))
    location = CrissCross.delete_key(store, loc)
    Store.close(store)
    encode_redis_string(location)
  end

  def handle_stateless(["SQL", tree, statement | rest], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree))
    {location, return} = CrissCross.sql(store, make_store, [statement | rest])
    Store.close(store)
    encode_redis_list([location] ++ Enum.map(return, &serialize_bert/1))
  end

  def handle_stateless(["SQLJSON", tree, statement | rest], %{
        external_port: external_port,
        make_store: make_store
      }) do
    {:ok, store} = make_store.(clean_maybe(tree))
    {location, return} = CrissCross.sql(store, make_store, [statement | rest])
    Store.close(store)
    return = return |> Enum.map(fn {status, v} -> [status, v] end)
    encode_redis_list([location] ++ Enum.map(return, &Jason.encode!/1))
  end

  def handle_stateless(["ANNOUNCE", cluster, tree, ttl], %{
        external_port: external_port,
        make_store: make_store
      }) do
    {:ok, store} = make_store.(clean_maybe(tree))

    ret =
      case Integer.parse(ttl) do
        {num, _} when num >= -1 ->
          :ok = CrissCross.announce(store, cluster, tree, external_port, num)
          "+OK\r\n"

        _ ->
          "-Invalid TTL Integer\r\n"
      end

    Store.close(store)
    ret
  end

  def handle_stateless(["HASANNOUNCED", cluster, tree], %{
        external_port: external_port,
        make_store: make_store
      }) do
    {:ok, store} = make_store.(clean_maybe(tree))

    ret =
      case CrissCross.has_announced(store, cluster, tree) do
        true ->
          encode_redis_integer(1)

        _ ->
          encode_redis_integer(0)
      end

    Store.close(store)
    ret
  end

  def handle_stateless(["POINTERLOOKUP", cluster, name, generation], _state) do
    case Integer.parse(generation) do
      {num, _} when num >= 0 ->
        case CrissCross.find_pointer(cluster, name, num) do
          name when is_binary(name) -> encode_redis_string(name)
          :timeout -> "$-1\r\n"
          :not_found -> "$-1\r\n"
          {:error, e} -> "-Error setting pointer #{inspect(e)}\r\n"
        end

      _ ->
        "-Invalid generation\r\n"
    end
  end

  def handle_stateless(["PUSH", cluster, tree, ttl], %{
        external_port: external_port,
        make_store: make_store
      }) do
    case Integer.parse(ttl) do
      {num, _} when num >= -1 ->
        {:ok, store} = make_store.(clean_maybe(tree))
        :ok = CrissCross.announce(store, cluster, tree, external_port, num)
        CrissCrossDHT.store(cluster, tree, num)
        Store.close(store)
        "+OK\r\n"

      _ ->
        "-Invalid generation\r\n"
    end
  end

  def handle_stateless(["POINTERLOOKUP", cluster, name, generation], _state) do
    case Integer.parse(generation) do
      {num, _} when num >= 0 ->
        case CrissCross.find_pointer(cluster, name, num) do
          name when is_binary(name) -> encode_redis_string(name)
          :timeout -> "$-1\r\n"
          :not_found -> "$-1\r\n"
          {:error, e} -> "-Error setting pointer #{inspect(e)}\r\n"
        end

      _ ->
        "-Invalid generation\r\n"
    end
  end

  def handle_stateless(["POINTERSET", cluster, private_key_pem, value, ttl], _state) do
    case DHTUtils.load_private_key(private_key_pem) do
      {:ok, private_key} ->
        case Integer.parse(ttl) do
          {num, _} when num >= -1 ->
            case CrissCross.set_pointer(cluster, private_key, value, num) do
              {l, _} -> encode_redis_string(l)
              {:error, e} -> "-#{inspect(e)}\r\n"
            end

          _ ->
            "-Invalid generation\r\n"
        end

      _ ->
        "-Invalid private key\r\n"
    end
  end

  def handle_stateless(["KEYPAIR"], _state) do
    {:ok, pub, priv} = ExSchnorr.keypair()
    {:ok, pub_bytes} = ExSchnorr.public_to_bytes(pub)
    {:ok, priv_bytes} = ExSchnorr.private_to_bytes(priv)
    encode_redis_list([hash(hash(pub_bytes)), pub_bytes, priv_bytes])
  end

  def handle_stateless(["CLUSTER"], _state) do
    {:ok, pub, priv} = ExSchnorr.keypair()
    {:ok, pub_bytes} = ExSchnorr.public_to_bytes(pub)
    {:ok, priv_bytes} = ExSchnorr.private_to_bytes(priv)
    cypher = DHTUtils.gen_cypher()
    name = hash(DHTUtils.combine_to_sign([cypher, pub_bytes]))
    encode_redis_list([name, cypher, pub_bytes, priv_bytes])
  end

  def handle_stateless(c, _) do
    Logger.error("Invalid command #{inspect(c)}")
    "-Invalid command\r\n"
  end

  def clean_maybe("nil"), do: nil
  def clean_maybe(""), do: nil
  def clean_maybe(v), do: v

  def clean_bool("true"), do: true
  def clean_bool(_), do: false
end
