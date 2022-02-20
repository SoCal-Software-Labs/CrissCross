defmodule CrissCross.ExternalRedis do
  require Logger

  import CrissCross.Utils
  import CrissCrossDHT.Server.Utils, only: [encrypt: 2, decrypt: 2, tuple_to_ipstr: 2]

  @doc """
  {:ok, conn} = Redix.start_link(host: "localhost", port: 57473)
  Redix.command(conn, ["WOW", "cool"])
  """

  @max_command_size 1000
  @max_connections_second 10
  @max_commands_second 1000
  @max_connections_ip 10
  @auth_commands [
    "EXCHANGEKEY",
    "VERIFY"
  ]

  def accept(port, make_make_store) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, active: true, reuseaddr: true])
    Logger.info("External TCP accepting connections on port #{port}")
    {:ok, local_store} = make_make_store.().(nil, nil)
    loop_acceptor(socket, %{command_size: 0, local_store: local_store})
  end

  defp loop_acceptor(socket, state) do
    {:ok, client} = :gen_tcp.accept(socket)
    {:ok, {ip, _port}} = :inet.peername(client)
    ip = tuple_to_ipstr(ip, 0)
    Logger.info("New external TCP connection #{inspect(ip)}")

    case Hammer.check_rate("new_connections:#{ip}", 60_000, @max_connections_second) do
      {:allow, _count} ->
        connection_count = Registry.count_match(CrissCross.ConnectionRegistry, ip, {:_, :_, :_})

        if connection_count < @max_connections_ip do
          {:ok, pid} =
            Task.Supervisor.start_child(CrissCross.TaskSupervisor, fn ->
              {:ok, _} = Registry.register(CrissCross.ConnectionRegistry, ip, client)
              serve(client, %{continuation: nil}, Map.put(state, :ip, ip))
            end)

          :ok = :gen_tcp.controlling_process(client, pid)
        else
          Logger.warning("Too many active connections #{ip}")
          :gen_tcp.send(socket, encode_redis_error("Too many active connections"))
        end

      {:deny, _limit} ->
        # deny the request
        Logger.warning("Rate limit #{ip}")
        :gen_tcp.send(socket, encode_redis_error("Rate limit connect"))
    end

    loop_acceptor(socket, state)
  end

  defp serve(socket, %{continuation: nil}, state) do
    receive do
      {:tcp, ^socket, data} -> handle_parse(socket, Redix.Protocol.parse(data), state)
      {:tcp_closed, ^socket} -> :ok
    end
  end

  defp serve(socket, %{continuation: fun}, %{command_size: command_size} = state) do
    receive do
      {:tcp, ^socket, data} ->
        new_command_size = byte_size(data) + command_size

        if new_command_size > @max_command_size do
          Logger.warn("External TCP connection closed because maximum command size exceeded")
          :gen_tcp.send(socket, encode_redis_error("Command too big"))
          :ok
        else
          handle_parse(socket, fun.(data), %{state | command_size: new_command_size})
        end

      {:tcp_closed, ^socket} ->
        :ok
    end
  end

  defp handle_parse(socket, {:continuation, fun}, state) do
    serve(socket, %{continuation: fun}, state)
  end

  defp handle_parse(socket, {:ok, req, left_over}, state) do
    state = %{state | command_size: 0}

    new_state = check_rate(socket, req, state)

    case left_over do
      "" -> serve(socket, %{continuation: nil}, new_state)
      _ -> handle_parse(socket, Redix.Protocol.parse(left_over), new_state)
    end
  end

  def check_rate(socket, req, state) do
    case Hammer.check_rate("commands:#{state.ip}", 60_000, @max_commands_second) do
      {:allow, _count} ->
        {resp, new_state} = handle(req, state)

        :gen_tcp.send(socket, resp)
        new_state

      {:deny, _limit} ->
        Process.sleep(100)
        check_rate(socket, req, state)
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
          _ -> {encode_redis_error("Error decrypting location"), state}
        end

      _ ->
        {encode_redis_error("Missing Secret"), state}
    end
  end

  def handle(["DO", payload], %{cluster: cluster, local_store: local_store} = state) do
    case state do
      %{secret: secret} ->
        case decrypt(payload, secret) do
          decrypted when is_binary(decrypted) ->
            case deserialize_bert(decrypted) do
              {location, method, argument, timeout}
              when is_binary(location) and is_binary(method) and is_binary(argument) and
                     is_integer(timeout) ->
                if CrissCross.has_announced(local_store, cluster, location) do
                  {handle_do(location, method, argument, timeout), state}
                else
                  {encode_redis_error("Peer not doing that now"), state}
                end

              _ ->
                {encode_redis_error("Invalid payload"), state}
            end

          _ ->
            {encode_redis_error("Error decrypting payload"), state}
        end

      _ ->
        {encode_redis_error("Missing Secret"), state}
    end
  end

  def handle_do(tree, method, argument, timeout) do
    t =
      Task.async(fn ->
        ref = make_ref()

        :ok =
          CrissCross.ProcessQueue.add_to_queue(
            tree,
            {tree <> method <> argument, method, argument, timeout, ref, self()}
          )

        receive do
          {^ref, resp, signature} ->
            encode_redis_list([resp, signature])

          {ref, :queue_too_big} ->
            encode_redis_error("Queue too big")
        after
          timeout ->
            encode_redis_error("Timeout")
        end
      end)

    Task.await(t, timeout + 100)
  end

  def do_get(%{cluster: cluster, local_store: local_store} = state, loc, secret) do
    if CrissCross.has_announced(local_store, cluster, loc) do
      case CubDB.Store.get_node(local_store, {0, loc}) do
        nil ->
          {"$-1\r\n", state}

        val ->
          bin = serialize_bert(val)

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
