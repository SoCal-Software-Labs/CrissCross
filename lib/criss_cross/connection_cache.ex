defmodule CrissCross.ConnectionCache do
  @encrypt true

  import CrissCross.Utils
  import CrissCrossDHT.Server.Utils, only: [encrypt: 2]

  use GenServer

  alias CubDB.Store
  alias CrissCross.ConnectionCache
  alias CrissCrossDHT.Server.Utils

  require Logger

  @interval 60 * 1000

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def get_conn(cluster, ip, port) do
    GenServer.call(__MODULE__, {:get_conn, {cluster, ip, port}})
  end

  @impl true
  def init(:ok) do
    {:ok, %{conns: %{}, timers: %{}}}
  end

  @impl true
  def handle_info(
        {:close, {cluster, ip, port} = ip_port},
        %{conns: conns, timers: timers} = state
      ) do
    new_conns =
      case Map.pop(conns, ip_port) do
        {nil, new_conns} ->
          new_conns

        {{:encrypted, conn, _}, new_conns} ->
          GenServer.stop(conn)
          new_conns

        {{:unencrypted, conn}, new_conns} ->
          GenServer.stop(conn)
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
        case timers do
          %{^ip_port => timer} -> Process.cancel_timer(timer)
          _ -> :ok
        end

        timer_ref = Process.send_after(self(), {:close, ip_port}, @interval)
        {:reply, {:ok, conn}, %{state | timers: Map.put(timers, ip_port, timer_ref)}}

      _ ->
        case connect(cluster, ip, port) do
          {:ok, conn} ->
            timer_ref = Process.send_after(self(), {:close, ip_port}, @interval)
            new_timers = Map.put(timers, ip_port, timer_ref)
            new_conns = Map.put(conns, ip_port, conn)
            {:reply, {:ok, conn}, %{state | timers: new_timers, conns: new_conns}}

          e ->
            e
        end
    end
  end

  def connect(cluster, {a, b, c, d} = remote_ip, port) do
    r =
      case Redix.start_link(
             host: "#{a}.#{b}.#{c}.#{d}",
             port: port
           ) do
        {:ok, conn} ->
          if @encrypt do
            {public_key, private_key} = :crypto.generate_key(:ecdh, :x25519)

            case Redix.command(conn, ["EXCHANGEKEY", public_key]) do
              {:ok, [other_public, token]} ->
                secret = :crypto.compute_key(:ecdh, other_public, private_key, :x25519)
                response = encrypt_cluster_message(cluster, token)
                cluster_id_reponse = encrypt(secret, cluster)

                case Redix.command(conn, ["VERIFY", cluster_id_reponse, response]) do
                  {:ok, "OK"} ->
                    {:commit, {:encrypted, conn, secret}}

                  e ->
                    {:ignore, e}
                end

              e ->
                {:ignore, e}
            end
          else
            {:commit, {:unencrypted, conn}}
          end

        e ->
          {:ignore, e}
      end

    case r do
      {:ignore, e} ->
        e

      {_, wrapped} ->
        conn =
          case wrapped do
            {:unencrypted, conn} -> conn
            {:encrypted, conn, _secret} -> conn
          end

        if Process.alive?(conn) do
          case Redix.command(conn, ["PING"]) do
            {:ok, "PONG"} ->
              {:ok, wrapped}

            _ ->
              {:error, "Remote connection not responding"}
          end
        else
          Cachex.del(:connection_cache, {remote_ip, port, cluster})
          get_conn(cluster, remote_ip, port)
        end
    end
  end
end
