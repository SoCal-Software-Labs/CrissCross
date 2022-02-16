defmodule CrissCross.ExternalRedis do
  require Logger

  import CrissCross.Utils
  import CrissCrossDHT.Server.Utils, only: [encrypt: 2, decrypt: 2]

  @doc """
  {:ok, conn} = Redix.start_link(host: "localhost", port: 57473)
  Redix.command(conn, ["WOW", "cool"])

  """

  def accept(port, local_redis_opts) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, active: true, reuseaddr: true])
    Logger.info("External TCP accepting connections on port #{port}")
    {:ok, redis_conn} = Redix.start_link(local_redis_opts)
    {:ok, local_store} = CrissCross.Store.Local.create(redis_conn, nil, nil)
    loop_acceptor(socket, %{local_store: local_store})
  end

  defp loop_acceptor(socket, state) do
    {:ok, client} = :gen_tcp.accept(socket)
    Logger.info("New external TCP connection")

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
    {resp, new_state} = handle(req, state)

    :gen_tcp.send(socket, resp)

    case left_over do
      "" -> serve(socket, %{continuation: nil}, new_state)
      _ -> handle_parse(socket, Redix.Protocol.parse(left_over), new_state)
    end
  end

  def handle(["AUTH", _, _], state) do
    {encode_redis_error("AUTH not supported - Use Handshake"), state}
  end

  def handle(["PING"], state) do
    {encode_redis_string("PONG"), state}
  end

  def handle(["EXCHANGEKEY", other_public], state) do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :x25519)
    secret = :crypto.compute_key(:ecdh, other_public, private_key, :x25519)
    token = new_challenge_token()
    new_state = Map.merge(state, %{secret: secret, token: token})
    {encode_redis_list([public_key, token]), new_state}
  end

  def handle(
        ["VERIFY", cluster_id_encrypted, token_encrypted],
        %{secret: secret, token: token} = state
      ) do
    case decrypt(cluster_id_encrypted, secret) do
      cluster_id when is_binary(cluster_id) ->
        case decrypt_cluster_message(cluster_id, token_encrypted) do
          response when is_binary(response) ->
            if response == token do
              {redis_ok(), Map.put(state, :cluster, cluster_id)}
            else
              {encode_redis_error("Invalid token"), state}
            end

          _ ->
            {encode_redis_error("Error decrypting token"), state}
        end

      _ ->
        {encode_redis_error("Error decrypting cluster"), state}
    end
  end

  def handle(["GET", loc], state) do
    case state do
      %{secret: secret} ->
        case decrypt(loc, secret) do
          location when is_binary(location) -> do_get(state, location, secret)
          _ -> encode_redis_error("Error decrypting location")
        end

      _ ->
        do_get(state, loc, nil)
    end
  end

  def do_get(%{cluster: cluster, local_store: local_store} = state, loc, secret) do
    if CrissCross.has_announced(local_store, cluster, loc) do
      case CubDB.Store.get_node(local_store, {0, loc}) do
        nil ->
          {"$-1\r\n", state}

        val ->
          bin = :erlang.term_to_binary(val)

          ret =
            case secret do
              nil -> bin
              secret -> encrypt(secret, bin)
            end

          {encode_redis_string(ret), state}
      end
    else
      {"$-1\r\n", state}
    end
  end
end
