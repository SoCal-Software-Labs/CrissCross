defmodule CrissCross.VPNClient do
  alias CrissCross.PeerGroup
  import CrissCross.Utils
  alias CrissCrossDHT.Server.Utils, as: DHTUtils
  require Logger

  @max_attempts 3

  def shutdown_port(local_port) do
    Registry.dispatch(CrissCross.VPNClientRegistry, local_port, fn entries ->
      for {_pid, socket} <- entries, do: :gen_tcp.close(socket)
    end)
  end

  def start_listening(cluster, tree, public_token, local_port, host, port) do
    case Registry.lookup(CrissCross.VPNClientRegistry, local_port) do
      [] ->
        {:ok, peer_group} = PeerGroup.start_link(cluster, 1, tree)
        try_listen_peer_group(peer_group, cluster, tree, public_token, local_port, host, port)

      [_ | _] ->
        {:error, "port taken"}
    end
  end

  def try_listen_peer_group(peer_group, cluster, tree, public_token, local_port, host, port) do
    try do
      if PeerGroup.has_peer(peer_group, 5000) do
        case PeerGroup.get_conns(peer_group, 5_000) do
          [] ->
            {:error, "No available connections."}

          [{:quic, endpoint, conn, {ip, conn_port}} = peer_conn | _] ->
            peer_addr = DHTUtils.tuple_to_ipstr(ip, conn_port)

            case ExP2P.bidirectional_open(endpoint, conn, self()) do
              {:ok, stream} ->
                challenge = :crypto.strong_rand_bytes(40)

                argument =
                  "vpn-verify" <>
                    serialize_bert({
                      cluster,
                      encrypt_cluster_message(
                        cluster,
                        serialize_bert({host, port, tree, public_token, challenge})
                      )
                    })

                ExP2P.stream_send(endpoint, stream, argument, 10_000)

                result =
                  receive do
                    {:new_stream_message, msg} ->
                      case deserialize_bert(msg) do
                        {false, _, _} ->
                          false

                        {true, key_bytes, sig} ->
                          case DHTUtils.load_public_key(key_bytes) do
                            {:ok, key} ->
                              name = DHTUtils.name_from_public_key(key)

                              if name == tree do
                                if DHTUtils.verify_signature(key, challenge, sig) do
                                  true
                                else
                                  Logger.warning("Invalid signature from #{peer_addr}")
                                  false
                                end
                              else
                                Logger.warning("Public key does not match name from #{peer_addr}")
                                false
                              end

                            {:error, _e} ->
                              Logger.warning("Invalid public key from #{peer_addr}")
                              false
                          end
                      end

                    :stream_finished ->
                      Logger.warning("Invalid no response from #{peer_addr}")
                      false
                  end

                if result do
                  Task.Supervisor.start_child(CrissCross.TaskSupervisor, fn ->
                    {:ok, peer_group} = PeerGroup.start_link(cluster, 1, tree)

                    try do
                      accept(peer_group, cluster, tree, public_token, local_port, host, port)
                    after
                      PeerGroup.stop(peer_group)
                    end
                  end)
                else
                  Logger.warning("Tunnel: Destination not supported by #{peer_addr}")
                  PeerGroup.bad_conn(peer_group, peer_conn)

                  try_listen_peer_group(
                    peer_group,
                    cluster,
                    tree,
                    public_token,
                    local_port,
                    host,
                    port
                  )
                end

              {:error, e} ->
                {:error, e}
            end
        end
      else
        {:error, "Tunnel: No available peers."}
      end
    rescue
      e ->
        Logger.error("Tunnel: Error initializing stream #{inspect(e)}")
        PeerGroup.stop(peer_group)
    end
  end

  def accept(peer_group, cluster, tree, public_token, local_port, host, port) do
    {:ok, socket} = :gen_tcp.listen(local_port, [:binary, active: :once, reuseaddr: true])
    Logger.info("Tunneling TCP connections on port #{local_port} to #{host}:#{port}")
    Registry.register(CrissCross.VPNClientRegistry, local_port, socket)

    loop_acceptor(peer_group, cluster, tree, public_token, local_port, host, port, socket)
  end

  defp loop_acceptor(peer_group, cluster, tree, public_token, local_port, host, port, socket) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        {:ok, pid} =
          Task.Supervisor.start_child(CrissCross.TaskSupervisor, fn ->
            Registry.register(CrissCross.VPNClientRegistry, local_port, socket)

            start_stream(
              peer_group,
              client,
              cluster,
              tree,
              public_token,
              host,
              port,
              0
            )
          end)

        :ok = :gen_tcp.controlling_process(client, pid)

        loop_acceptor(peer_group, cluster, tree, public_token, local_port, host, port, socket)

      {:error, _} ->
        Logger.info("Stopping TCP connections on port #{local_port}")
        :ok
    end
  end

  def start_stream(
        peer_group,
        socket,
        cluster,
        tree,
        public_token,
        host,
        port,
        attempt
      ) do
    if PeerGroup.has_peer(peer_group, 5000) do
      case PeerGroup.get_conns(peer_group, 5_000) do
        [] ->
          Logger.warning("Tunnel: no connections")

          if attempt < @max_attempts do
            PeerGroup.restart_search(peer_group)
            Process.sleep(1000 * attempt)
            start_stream(peer_group, socket, cluster, tree, public_token, host, port, attempt + 1)
          end

        [{:quic, endpoint, conn, {ip, conn_port}} = peer_conn | _] ->
          peer_addr = DHTUtils.tuple_to_ipstr(ip, conn_port)

          case ExP2P.bidirectional_open(endpoint, conn, self()) do
            {:ok, stream} ->
              challenge = :crypto.strong_rand_bytes(40)

              argument =
                "vpn-new" <>
                  serialize_bert({
                    cluster,
                    encrypt_cluster_message(
                      cluster,
                      serialize_bert({host, port, tree, public_token, challenge})
                    )
                  })

              ExP2P.stream_send(endpoint, stream, argument, 10_000)

              receive do
                {:new_stream_message, msg} ->
                  case deserialize_bert(decrypt_cluster_message(cluster, msg)) do
                    {:error, error} ->
                      Logger.error("Tunnel: #{peer_addr} #{error}")
                      PeerGroup.bad_conn(peer_group, peer_conn)

                      start_stream(
                        peer_group,
                        socket,
                        cluster,
                        tree,
                        public_token,
                        host,
                        port,
                        attempt
                      )

                    {:ref, ref, key_bytes, sig} ->
                      case DHTUtils.load_public_key(key_bytes) do
                        {:ok, key} ->
                          name = DHTUtils.name_from_public_key(key)

                          if name == tree do
                            if DHTUtils.verify_signature(key, challenge, sig) do
                              loop(endpoint, stream, tree, socket, ref, 0, 0)
                            else
                              Logger.warning(
                                "Tunnel: #{peer_addr} New connection returned invalid signature"
                              )

                              PeerGroup.bad_conn(peer_group, peer_conn)

                              start_stream(
                                peer_group,
                                socket,
                                cluster,
                                tree,
                                public_token,
                                host,
                                port,
                                attempt
                              )
                            end
                          else
                            Logger.warning(
                              "Tunnel: #{peer_addr} New connection public key did not match name"
                            )

                            PeerGroup.bad_conn(peer_group, peer_conn)

                            start_stream(
                              peer_group,
                              socket,
                              cluster,
                              tree,
                              public_token,
                              host,
                              port,
                              attempt
                            )
                          end

                        {:error, _e} ->
                          Logger.warning(
                            "Tunnel: #{peer_addr} New connection returned invalid public key"
                          )

                          PeerGroup.bad_conn(peer_group, peer_conn)

                          start_stream(
                            peer_group,
                            socket,
                            cluster,
                            tree,
                            public_token,
                            host,
                            port,
                            attempt
                          )
                      end
                  end

                :stream_finished ->
                  :ok
              end

            {:error, error} ->
              Logger.error("Tunnel: #{peer_addr} #{error} | Attempting to reconnect.")
              PeerGroup.bad_conn(peer_group, peer_conn)
              start_stream(peer_group, socket, cluster, tree, public_token, host, port, attempt)
          end
      end
    else
      Logger.warning("Tunnel: No available peers. Looking for new ones.")

      if attempt < @max_attempts do
        PeerGroup.restart_search(peer_group)
        Process.sleep(1000 * attempt)
        start_stream(peer_group, socket, cluster, tree, public_token, host, port, attempt + 1)
      end
    end
  end

  def loop(endpoint, stream, tree, socket, ref, reader_num, number) do
    receive do
      {:tcp, ^socket, data} ->
        :inet.setopts(socket, active: :once)
        argument = "vpn-msg" <> serialize_bert({ref, number, data})

        ret =
          ExP2P.stream_send(
            endpoint,
            stream,
            argument,
            10_000
          )

        case ret do
          :ok ->
            loop(endpoint, stream, tree, socket, ref, reader_num, number + 1)

          {:error, e} ->
            Logger.error("VPN stream error. #{e}.")
            :ok
        end

      {:tcp_closed, ^socket} ->
        argument = "vpn-close" <> ref

        _ =
          ExP2P.stream_send(
            endpoint,
            stream,
            argument,
            10_000
          )

        :ok

      {:new_stream_message, msg} ->
        {num, bytes} = deserialize_bert(msg)

        if num == reader_num do
          :gen_tcp.send(socket, bytes)
          loop(endpoint, stream, tree, socket, ref, reader_num + 1, number)
        else
          if num < reader_num do
            loop(endpoint, stream, tree, socket, ref, reader_num, number)
          else
            Logger.error("Tunnel stream out of sync. Stopping.")
            :ok
          end
        end

      :stream_finished ->
        :gen_tcp.shutdown(socket, :read_write)
    end
  end
end
