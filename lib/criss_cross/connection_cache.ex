defmodule CrissCross.ConnectionCache do
  import CrissCross.Utils
  import CrissCrossDHT.Server.Utils, only: [tuple_to_ipstr: 2]

  use GenServer

  require Logger

  @interval 60 * 1000
  @ping_timeout 3000
  @pong_reply serialize_bert({:ok, "PONG"})

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def get_conn(cluster, ip, port) do
    GenServer.call(__MODULE__, {:get_conn, {cluster, ip, port}})
  end

  def return(conn) do
    GenServer.cast(__MODULE__, {:return, conn})
  end

  def command({:quic, endpoint, conn, _}, command, cluster, payload, timeout) do
    encrypted = encrypt_cluster_message(cluster, payload)

    ret =
      ExP2P.pseudo_bidirectional(
        endpoint,
        conn,
        serialize_bert([command, cluster, encrypted]),
        timeout
      )

    case ret do
      {:ok, s} -> deserialize_bert(s)
      e -> e
    end
  end

  @impl true
  def init(:ok) do
    send(self(), :start)
    {:ok, %{endpoint: nil, conns: %{}, timers: %{}}}
  end

  def handle_info(:start, state) do
    {:ok, endpoint, _} = ExP2P.Dispatcher.endpoint(ExP2P.Dispatcher)
    {:noreply, %{state | endpoint: endpoint}}
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

        {{:quic, _endpoint, _conn, _}, new_conns} ->
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
  def handle_info(
        {:delete, ip_port},
        %{conns: conns, timers: timers} = state
      ) do
    {:noreply, %{state | conns: Map.delete(conns, ip_port), timers: Map.delete(timers, ip_port)}}
  end

  @impl true
  def handle_call(
        {:get_conn, {cluster, ip, port} = ip_port},
        reply_to,
        %{endpoint: endpoint, conns: conns, timers: timers} = state
      ) do
    outer = self()

    Task.start(fn ->
      case conns do
        %{^ip_port => conn} ->
          case ExP2P.pseudo_bidirectional(endpoint, conn, serialize_bert(["PING"]), @ping_timeout) do
            {:ok, @pong_reply} ->
              case timers do
                %{^ip_port => timer} -> Process.cancel_timer(timer)
                _ -> :ok
              end

              send(outer, {:delete, ip_port})
              GenServer.reply(reply_to, {:ok, conn})

            _ ->
              case connect(endpoint, cluster, ip, port) do
                {:ok, conn} ->
                  send(outer, {:delete, ip_port})
                  GenServer.reply(reply_to, {:ok, conn})

                e ->
                  Cachex.put!(:blacklisted_ips, {ip, port}, true)
                  GenServer.reply(reply_to, e)
              end
          end

        _ ->
          case connect(endpoint, cluster, ip, port) do
            {:ok, conn} ->
              GenServer.reply(reply_to, {:ok, conn})

            e ->
              Cachex.put!(:blacklisted_ips, {ip, port}, true)
              GenServer.reply(reply_to, e)
          end
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:return, conn}, %{conns: conns, timers: timers} = state) do
    ip_port = conn_ip_tuple(conn)
    timer_ref = Process.send_after(self(), {:close, ip_port}, @interval)
    new_timers = Map.put(timers, ip_port, timer_ref)
    new_conns = Map.put(conns, ip_port, conn)
    {:noreply, %{state | timers: new_timers, conns: new_conns}}
  end

  def conn_ip_tuple({:quic, _, _, ip_tuple}), do: ip_tuple

  def connect(endpoint, _cluster, remote_ip, port) do
    r =
      case ExP2P.connect(endpoint, [tuple_to_ipstr(remote_ip, port)], @ping_timeout) do
        {:ok, conn} ->
          case ExP2P.pseudo_bidirectional(endpoint, conn, serialize_bert(["PING"]), @ping_timeout) do
            {:ok, @pong_reply} -> {:commit, {:quic, endpoint, conn, {remote_ip, port}}}
            e -> {:ignore, e}
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
