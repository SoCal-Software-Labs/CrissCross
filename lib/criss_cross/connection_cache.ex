defmodule CrissCross.ConnectionCache do
  @encrypt true

  import CrissCross.Utils
  import CrissCrossDHT.Server.Utils, only: [encrypt: 2]

  use GenServer

  require Logger

  @interval 60 * 1000
  @ping_timeout 3000

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def get_conn(cluster, ip, port) do
    GenServer.call(__MODULE__, {:get_conn, {cluster, ip, port}})
  end

  def return(conn) do
    GenServer.cast(__MODULE__, {:return, conn})
  end

  def command({:unencrypted, conn, _}, command, arg, timeout) do
    Redix.command(conn, [command, arg], timeout: timeout)
  end

  def command({:encrypted, conn, secret, _}, command, arg, timeout) do
    payload = encrypt(secret, arg)
    Redix.command(conn, [command, payload], timeout: timeout)
  end

  @impl true
  def init(:ok) do
    {:ok, %{conns: %{}, timers: %{}}}
  end

  @impl true
  def handle_info(
        {:close, ip_port},
        %{conns: conns, timers: timers} = state
      ) do
    new_conns =
      case Map.pop(conns, ip_port) do
        {nil, new_conns} ->
          new_conns

        {{:encrypted, conn, _, _}, new_conns} ->
          Redix.stop(conn)
          new_conns

        {{:unencrypted, conn, _}, new_conns} ->
          Redix.stop(conn)
          new_conns
      end

    new_timers =
      case Map.pop(timers, ip_port) do
        {nil, new_timers} ->
          new_timers

        {timer, new_timers} ->
          Process.cancel_timer(timer)
          new_timers
      end

    {:noreply, %{state | conns: new_conns, timers: new_timers}}
  end

  @impl true
  def handle_call(
        {:get_conn, {cluster, ip, port} = ip_port},
        _,
        %{conns: conns, timers: timers} = state
      ) do
    case conns do
      %{^ip_port => conn} ->
        case Redix.command(conn, ["PING"], timeout: @ping_timeout) do
          {:ok, "PONG"} ->
            case timers do
              %{^ip_port => timer} -> Process.cancel_timer(timer)
              _ -> :ok
            end

            {:reply, {:ok, conn},
             %{state | conns: Map.delete(conns, ip_port), timers: Map.delete(timers, ip_port)}}

          _ ->
            case connect(cluster, ip, port) do
              {:ok, conn} ->
                {:reply, {:ok, conn},
                 %{state | conns: Map.delete(conns, ip_port), timers: Map.delete(timers, ip_port)}}

              e ->
                Cachex.put!(:blacklisted_ips, {ip, port}, true)
                {:reply, e, state}
            end
        end

      _ ->
        case connect(cluster, ip, port) do
          {:ok, conn} ->
            {:reply, {:ok, conn}, state}

          e ->
            Cachex.put!(:blacklisted_ips, {ip, port}, true)
            {:reply, e, state}
        end
    end
  end

  @impl true
  def handle_cast({:return, conn}, %{conns: conns, timers: timers} = state) do
    ip_port = conn_ip_tuple(conn)
    timer_ref = Process.send_after(self(), {:close, ip_port}, @interval)
    new_timers = Map.put(timers, ip_port, timer_ref)
    new_conns = Map.put(conns, ip_port, conn)
    {:noreply, %{state | timers: new_timers, conns: new_conns}}
  end

  def conn_ip_tuple({:encrypted, _, _, ip_tuple}), do: ip_tuple
  def conn_ip_tuple({:unencrypted, _, ip_tuple}), do: ip_tuple

  def connect(cluster, {a, b, c, d} = remote_ip, port) do
    r =
      case Redix.start_link(
             host: "#{a}.#{b}.#{c}.#{d}",
             port: port,
             timeout: @ping_timeout
           ) do
        {:ok, conn} ->
          if @encrypt do
            {public_key, private_key} = :crypto.generate_key(:ecdh, :x25519)

            case Redix.command(conn, ["EXCHANGEKEY", public_key], timeout: @ping_timeout) do
              {:ok, [other_public, token]} ->
                secret = :crypto.compute_key(:ecdh, other_public, private_key, :x25519)
                response = encrypt_cluster_message(cluster, token)
                cluster_id_reponse = encrypt(secret, cluster)

                case Redix.command(conn, ["VERIFY", cluster_id_reponse, response],
                       timeout: @ping_timeout
                     ) do
                  {:ok, "OK"} ->
                    {:commit, {:encrypted, conn, secret, {remote_ip, port}}}

                  e ->
                    {:ignore, e}
                end

              e ->
                {:ignore, e}
            end
          else
            {:commit, {:unencrypted, conn, {remote_ip, port}}}
          end

        e ->
          {:ignore, e}
      end

    case r do
      {:ignore, e} ->
        e

      {_, wrapped} ->
        {:ok, wrapped}
    end
  end
end
