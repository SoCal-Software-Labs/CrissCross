defmodule CrissCross.InternalRedis do
  require Logger

  alias CrissCross.Utils

  @doc """
  {:ok, conn} = Redix.start_link(host: "localhost", port: 35002)
  cluster = "CsFD25YQcZ6N179edKvhRkV9Nv75gjL6MwV16z5frniQ" |> CrissCross.decode_human!()
  {:ok, loc} = Redix.command(conn, ["PUT_MULTI", "", :erlang.term_to_binary("hello"), :erlang.term_to_binary("world")])
  Redix.command(conn, ["GET_MULTI", loc, :erlang.term_to_binary("hello")])

  Redix.command(conn, ["WOW", "cool"])

  """

  def accept(port, local_redis_opts) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, active: true, reuseaddr: true])
    Logger.info("Accepting connections on port #{port}")
    {:ok, redis_conn} = Redix.start_link(local_redis_opts)

    loop_acceptor(socket, %{redis_conn: redis_conn})
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
    resp =
      try do
        handle(req, state)
      rescue
        e in ArgumentError -> "-Invalid BERT encoding\r\n"
      end

    :gen_tcp.send(socket, resp)

    case left_over do
      "" -> serve(socket, %{continuation: nil}, state)
      _ -> handle_parse(socket, Redix.Protocol.parse(left_over), state)
    end
  end

  def handle(["SELECT", tree, query], %{redis_conn: redis_conn}) do
  end

  def handle(["GET_MULTI_BIN", tree, loc | locs], %{redis_conn: redis_conn}) do
    loc_terms = [loc | locs]
    res = CrissCross.get_multi(redis_conn, tree, loc_terms)

    Enum.flat_map([loc | locs], fn l ->
      case Map.get(res, l) do
        nil -> []
        val -> [l, val]
      end
    end)
    |> Utils.encode_redis_list()
  end

  def handle(["GET_MULTI", tree, loc | locs], %{redis_conn: redis_conn}) do
    loc_terms = [loc | locs] |> Enum.map(&Utils.deserialize_bert/1)
    res = CrissCross.get_multi(redis_conn, tree, loc_terms)

    Enum.flat_map(loc_terms, fn l ->
      case Map.get(res, l) do
        nil -> []
        val -> [l, val |> Utils.serialize_bert()]
      end
    end)
    |> Utils.encode_redis_list()
  end

  def handle(["FETCH", tree, loc], %{redis_conn: redis_conn}) do
    case CrissCross.fetch(redis_conn, tree, loc |> Utils.deserialize_bert()) do
      {:ok, value} -> Utils.encode_redis_string(value |> Utils.serialize_bert())
      :error -> "$-1\r\n"
    end
  end

  def handle(["FETCH_BIN", tree, loc], %{redis_conn: redis_conn}) do
    case CrissCross.fetch(redis_conn, tree, loc) do
      {:ok, value} -> Utils.encode_redis_string(value)
      :error -> "$-1\r\n"
    end
  end

  def handle(["HAS_KEY", tree, loc], %{redis_conn: redis_conn}) do
    case CrissCross.has_key?(redis_conn, tree, loc |> Utils.deserialize_bert()) do
      true -> Utils.encode_redis_integer(1)
      false -> Utils.encode_redis_integer(0)
    end
  end

  def handle(["HAS_KEY_BIN", tree, loc], %{redis_conn: redis_conn}) do
    case CrissCross.has_key?(redis_conn, tree, loc) do
      true -> Utils.encode_redis_integer(1)
      false -> Utils.encode_redis_integer(0)
    end
  end

  def handle(["PUT_MULTI", tree, key, value | kvs], %{redis_conn: redis_conn})
      when rem(length(kvs), 2) == 0 do
    terms =
      [key, value | kvs]
      |> Enum.chunk_every(2)
      |> Enum.map(fn [k, v] ->
        {Utils.deserialize_bert(k), Utils.deserialize_bert(v)}
      end)

    location = CrissCross.put_multi(redis_conn, tree, terms)
    Utils.encode_redis_string(location) |> IO.inspect()
  end

  def handle(["PUT_MULTI_BIN", tree, key, value | kvs], %{redis_conn: redis_conn})
      when rem(length(kvs), 2) == 0 do
    terms =
      [key, value | kvs]
      |> Enum.chunk_every(2)
      |> Enum.map(fn [k, v] ->
        {k, v}
      end)

    location = CrissCross.put_multi(redis_conn, tree, terms)
    Utils.encode_redis_string(location)
  end

  def handle(["DELETE_KEY", tree, loc], %{redis_conn: redis_conn}) do
    location = CrissCross.delete_key(redis_conn, tree, Utils.deserialize_bert(loc))
    Utils.encode_redis_string(location)
  end

  def handle(["DELETE_KEY_BIN", tree, loc], %{redis_conn: redis_conn}) do
    location = CrissCross.delete_key(redis_conn, tree, loc)
    Utils.encode_redis_string(location)
  end

  def handle(_, _) do
    "-Invalid command\r\n"
  end

  def clean_tree("nil"), do: nil
  def clean_tree(""), do: nil
  def clean_tree(v), do: v
end
