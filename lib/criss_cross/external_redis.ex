defmodule CrissCross.ExternalRedis do
  require Logger

  @doc """
  {:ok, conn} = Redix.start_link(host: "localhost", port: 57473)
  Redix.command(conn, ["WOW", "cool"])

  """
  @crlf_iodata [?\r, ?\n]

  def accept(port, local_redis_opts) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, active: true, reuseaddr: true])
    Logger.info("Accepting connections on port #{port}")
    {:ok, redis_conn} = Redix.start_link(local_redis_opts)
    {:ok, local_store} = CrissCross.Store.Local.create(redis_conn, nil)
    loop_acceptor(socket, %{local_store: local_store})
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

    IO.inspect(resp)

    :gen_tcp.send(socket, resp)

    case left_over do
      "" -> serve(socket, %{continuation: nil}, state)
      _ -> handle_parse(socket, Redix.Protocol.parse(left_over), state)
    end
  end

  def handle(["GET", loc], %{local_store: local_store}) do
    case CubDB.Store.get_node(local_store, loc) do
      nil ->
        "$-1\r\n"

      val ->
        bin = :erlang.term_to_binary(val)
        encode_string(bin)
    end
  end

  def encode_string(item) do
    [?$, Integer.to_string(byte_size(item)), @crlf_iodata, item, @crlf_iodata]
  end
end
