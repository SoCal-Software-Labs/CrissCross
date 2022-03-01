defmodule CrissCross.CommandQueue do
  import CrissCross.Utils
  alias CrissCross.Utils.{MissingHashError, DecoderError}
  alias CrissCrossDHT.Server.Utils, as: DHTUtils
  alias CrissCross.VPNConfig

  require Logger

  @max_commands_second 1000
  @max_timeout 30_000

  def new_state(_conn) do
    {:ok, pid} = Agent.start_link(fn -> %{} end)
    %{stream_agent: pid}
  end

  def handle_new_message("vpn" <> msg, sender, _from, endpoint, _local_store, _state) do
    try do
      case msg do
        "-msg" <> msg ->
          case deserialize_bert(msg) do
            {ref, num, data} ->
              case Registry.lookup(CrissCross.VPNRegistry, ref) do
                [] ->
                  Logger.warning("No available sockets for tunnel reference #{inspect(ref)}")
                  ExP2P.stream_finish(endpoint, sender)

                [{pid, _} | _] ->
                  send(pid, {ref, num, data})
              end

            other ->
              ExP2P.stream_finish(endpoint, sender)
              Logger.warning("Invalid Tunnel message format #{inspect(other)}")
          end

        "-close" <> ref ->
          case Registry.lookup(CrissCross.VPNRegistry, ref) do
            [] ->
              ExP2P.stream_finish(endpoint, sender)

            [{pid, _} | _] ->
              ExP2P.stream_finish(endpoint, sender)
              send(pid, {ref, :stop})
          end

        "-verify" <> b ->
          case deserialize_bert(b) do
            {cluster, msg} ->
              case deserialize_bert(decrypt_cluster_message(cluster, msg)) do
                {host, port, name, public_tunnel_token, challenge} ->
                  result = VPNConfig.get_vpn_key(cluster, name, host, port)

                  case result do
                    nil ->
                      ExP2P.stream_send(
                        endpoint,
                        sender,
                        serialize_bert({false, nil, nil}),
                        10_000
                      )

                    {^public_tunnel_token, private_key} ->
                      {:ok, signature} = DHTUtils.sign(challenge, private_key)
                      {:ok, pub_key} = ExSchnorr.public_from_private(private_key)
                      {:ok, encoded} = ExSchnorr.public_to_bytes(pub_key)

                      ExP2P.stream_send(
                        endpoint,
                        sender,
                        serialize_bert({true, encoded, signature}),
                        10_000
                      )

                    _ ->
                      Logger.warning("Tunnel: Connection refused because tokens did not match")

                      ExP2P.stream_send(
                        endpoint,
                        sender,
                        serialize_bert({false, nil, nil}),
                        10_000
                      )
                  end

                other ->
                  ExP2P.stream_finish(endpoint, sender)
                  Logger.error("Invalid Tunnel message format #{inspect(other)}")
              end

            other ->
              ExP2P.stream_finish(endpoint, sender)
              Logger.error("Invalid Tunnel message format #{inspect(other)}")
          end

        "-new" <> b ->
          case deserialize_bert(b) do
            {cluster, msg} ->
              case deserialize_bert(decrypt_cluster_message(cluster, msg)) do
                {host, port, name, public_tunnel_token, challenge} ->
                  case VPNConfig.get_vpn_key(cluster, name, host, port) do
                    nil ->
                      encrypted =
                        encrypt_cluster_message(
                          cluster,
                          serialize_bert({:error, "Invalid destination"})
                        )

                      Logger.error("Invalid VPN host and port #{host}:#{port}")
                      ExP2P.stream_send(endpoint, sender, encrypted, 10_000)
                      ExP2P.stream_finish(endpoint, sender)

                    {^public_tunnel_token, private_key} ->
                      {:ok, signature} = DHTUtils.sign(challenge, private_key)
                      {:ok, pub_key} = ExSchnorr.public_from_private(private_key)
                      {:ok, encoded} = ExSchnorr.public_to_bytes(pub_key)

                      ref = make_job_ref()
                      opts = [:binary, active: :once]
                      {:ok, socket} = :gen_tcp.connect(to_charlist(host), port, opts)

                      encrypted =
                        encrypt_cluster_message(
                          cluster,
                          serialize_bert({:ref, ref, encoded, signature})
                        )

                      ExP2P.stream_send(endpoint, sender, encrypted, 10_000)

                      {:ok, pid} =
                        Task.Supervisor.start_child(
                          CrissCross.TaskSupervisor,
                          fn ->
                            {:ok, _} = Registry.register(CrissCross.VPNRegistry, ref, nil)
                            loop_vpn(socket, ref, endpoint, sender, 0, 0)
                          end
                        )

                      :ok = :gen_tcp.controlling_process(socket, pid)

                    _ ->
                      Logger.warning("Tunnel: Connection refused because tokens did not match")

                      encrypted =
                        encrypt_cluster_message(
                          cluster,
                          serialize_bert({:error, "Invalid tunnel token"})
                        )

                      ExP2P.stream_send(endpoint, sender, encrypted, 10_000)
                      ExP2P.stream_finish(endpoint, sender)
                  end

                other ->
                  ExP2P.stream_finish(endpoint, sender)
                  Logger.error("Invalid Tunnel message format #{inspect(other)}")
              end

            other ->
              ExP2P.stream_finish(endpoint, sender)
              Logger.error("Invalid Tunnel message format #{inspect(other)}")
          end

        _ ->
          :ok
      end
    rescue
      e ->
        ExP2P.stream_finish(endpoint, sender)
        Logger.error("Error processing VPN message #{inspect(e)}")
    end
  end

  def handle_new_message(msg, sender, from, endpoint, local_store, state) do
    Task.start(fn -> queue_msg(msg, sender, from, endpoint, local_store, state, 0) end)
    state
  end

  def loop_vpn(socket, ref, endpoint, sender, reader_num, writer_num) do
    receive do
      {^ref, num, data} ->
        if num == reader_num do
          :gen_tcp.send(socket, data)
          loop_vpn(socket, ref, endpoint, sender, reader_num + 1, writer_num)
        else
          if num < reader_num do
            loop_vpn(socket, ref, endpoint, sender, reader_num, writer_num)
          else
            :ok
          end
        end

      {^ref, :stop} ->
        :ok

      {:tcp, ^socket, data} ->
        :inet.setopts(socket, active: :once)
        ExP2P.stream_send(endpoint, sender, serialize_bert({writer_num, data}), 10_000)
        loop_vpn(socket, ref, endpoint, sender, reader_num, writer_num + 1)

      {:tcp_closed, ^socket} ->
        :ok
    end
  end

  def write_error(endpoint, sender, msg) do
    :ok =
      ExP2P.stream_send(
        endpoint,
        sender,
        serialize_bert({:error, msg}),
        10_000
      )
  end

  def queue_msg(msg, sender, from, endpoint, local_store, state, tries) do
    case Hammer.check_rate("commands:#{from}", 1_000, @max_commands_second) do
      {:allow, _count} ->
        try do
          handle_msg(msg, sender, endpoint, state, from, local_store)
        rescue
          MissingHashError -> write_error(endpoint, sender, "Data not found")
          DecoderError -> write_error(endpoint, sender, "Invalid BERT Term")
          MissingClusterError -> write_error(endpoint, sender, "Cluster not found")
        end

      {:deny, _limit} ->
        if tries < 5 do
          Process.sleep(1000)
          queue_msg(msg, sender, from, endpoint, local_store, state, tries + 1)
        else
          :ok = ExP2P.stream_send(endpoint, sender, serialize_bert({:error, "Back off"}), 10_000)
        end
    end
  end

  defp handle_msg(msg, sender, endpoint, state, from, local_store) do
    ret =
      case deserialize_bert(msg) do
        ["PING"] ->
          serialize_bert({:ok, "PONG"})

        ["GET", cluster, loc_encrypted] ->
          ret = do_get(local_store, cluster, loc_encrypted)
          encrypt_cluster_message(cluster, serialize_bert(ret))

        ["DO", cluster, command_encrypted] ->
          ret = do_command(local_store, cluster, command_encrypted)
          encrypt_cluster_message(cluster, serialize_bert(ret))

        ["STREAM", cluster, command_encrypted] ->
          ret =
            do_stream(
              local_store,
              endpoint,
              sender,
              state.stream_agent,
              cluster,
              from,
              command_encrypted
            )

          case ret do
            :no_reply -> nil
            _ -> encrypt_cluster_message(cluster, serialize_bert(ret))
          end
      end

    if ret != nil do
      :ok = ExP2P.stream_send(endpoint, sender, ret, 10_000)
    end
  end

  def do_get(local_store, cluster, loc_encrypted) do
    case decrypt_cluster_message(cluster, loc_encrypted) do
      location when is_binary(location) ->
        if CrissCross.has_announced(local_store, cluster, location) do
          case CubDB.Store.get_node(local_store, {0, location}) do
            nil ->
              {:ok, nil}

            val ->
              bin = serialize_bert(val)

              {:ok, bin}
          end
        else
          {:ok, nil}
        end

      _ ->
        {:error, "Error decrypting token"}
    end
  end

  def subscribe_loop(key, ref, endpoint, sender, stream_agent) do
    resp =
      receive do
        {^ref, resp, signature} ->
          {:ok, [resp, signature]}

        {^ref, :queue_too_big} ->
          {:error, "Queue too big"}

        {^ref, :stop} ->
          :no_reply
      end

    case resp do
      :no_reply ->
        :ok

      _ ->
        case ExP2P.stream_send(endpoint, sender, serialize_bert(resp), 10_000) do
          :ok ->
            subscribe_loop(key, ref, endpoint, sender, stream_agent)

          _ ->
            Agent.update(stream_agent, fn streams -> Map.delete(streams, key) end)
        end
    end
  end

  def do_command(local_store, cluster, command_encrypted) do
    case decrypt_cluster_message(cluster, command_encrypted) do
      command when is_binary(command) ->
        case deserialize_bert(command) do
          [tree, method, argument, timeout | _] ->
            has_announced =
              Cachex.get!(:local_jobs, tree) != nil or
                CrissCross.has_announced(local_store, cluster, tree)

            if has_announced do
              t =
                Task.async(fn ->
                  ref = make_job_ref()

                  :ok =
                    CrissCross.ProcessQueue.add_to_queue(
                      tree,
                      {tree <> method <> argument, method, argument, timeout - 100, ref, self()}
                    )

                  {:error, "Error decrypting command"}

                  receive do
                    {^ref, resp, signature} ->
                      {:ok, [resp, signature]}

                    {^ref, :queue_too_big} ->
                      {:error, "Queue too big"}
                  after
                    timeout ->
                      {:error, "Timeout"}
                  end
                end)

              Task.await(t, timeout + 500)
            else
              {:error, "Not announcing"}
            end

          _ ->
            {:error, "Invalid command format"}
        end

      _ ->
        {:error, "Error decrypting command"}
    end
  end

  def do_stream(local_store, endpoint, sender, stream_agent, cluster, from, command_encrypted) do
    case decrypt_cluster_message(cluster, command_encrypted) do
      command when is_binary(command) ->
        case deserialize_bert(command) do
          [tree, method, argument, timeout, ref | _] ->
            has_announced =
              Cachex.get!(:local_jobs, tree) != nil or
                CrissCross.has_announced(local_store, cluster, tree)

            if has_announced do
              key = {from, ref}

              timeout = min(timeout, @max_timeout)

              {waiting_pid, local_ref} =
                if timeout > 0 do
                  Agent.get_and_update(stream_agent, fn streams ->
                    case Map.pop(streams, key) do
                      {{pid, local_ref, timer}, other_streams} ->
                        Process.cancel_timer(timer)
                        new_timer = Process.send_after(pid, {local_ref, :stop}, timeout)

                        {{pid, local_ref},
                         Map.put(other_streams, key, {pid, local_ref, new_timer})}

                      {nil, other_streams} ->
                        local_ref = make_job_ref()

                        {:ok, pid} =
                          Task.Supervisor.start_child(CrissCross.TaskSupervisor, fn ->
                            subscribe_loop(key, local_ref, endpoint, sender, stream_agent)
                          end)

                        new_timer = Process.send_after(pid, {local_ref, :stop}, timeout)

                        {{pid, local_ref},
                         Map.put(other_streams, key, {pid, local_ref, new_timer})}
                    end
                  end)
                else
                  nil
                end

              :ok =
                CrissCross.ProcessQueue.add_to_queue(
                  tree,
                  {tree <> method <> argument, method, argument, timeout - 100, local_ref,
                   waiting_pid}
                )

              :no_reply
            else
              {:error, "Not announcing"}
            end

          _ ->
            {:error, "Invalid command format"}
        end

      _ ->
        {:error, "Error decrypting command"}
    end
  end
end
