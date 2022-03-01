defmodule CrissCross.PeerGroup do
  use GenServer

  alias CrissCross.ConnectionCache

  require Logger

  def start_link(cluster, target, tree_hash) do
    GenServer.start_link(__MODULE__, [cluster, target, tree_hash])
  end

  def has_peer(pid, timeout) do
    ref = make_ref()
    GenServer.cast(pid, {:has_peer, self(), ref})

    receive do
      {^ref, result} -> result
    after
      timeout -> false
    end
  end

  def bad_conn(pid, conn) do
    GenServer.cast(pid, {:bad_conn, conn})
  end

  def stop(pid) do
    GenServer.cast(pid, :stop)
  end

  def restart_search(pid) do
    send(pid, :start)
  end

  def get_conns(pid, timeout) do
    ref = make_ref()
    GenServer.cast(pid, {:get_connections, self(), ref})

    receive do
      {^ref, conns} -> conns
    after
      timeout ->
        []
    end
  end

  def init([cluster, target, tree_hash]) do
    send(self(), :start)

    {:ok,
     %{
       cluster: cluster,
       target: target,
       tree_hash: tree_hash,
       peers_with_conns: [],
       peers: [],
       active_connections: %{},
       waiting_connection: [],
       waiting_has_peer: []
     }}
  end

  def start_search(%{cluster: cluster, tree_hash: tree_hash, target: target} = state)
      when is_number(target) do
    task_pid = self()

    CrissCrossDHT.search(cluster, tree_hash, fn
      :done ->
        send(task_pid, :done)

      {ip, port, meta, _} ->
        n = %{ip: ip, port: port, meta: meta}

        if Cachex.get(:blacklisted_ips, {ip, port}) == {:ok, nil} do
          send(task_pid, {:new_peer, n})
        end
    end)

    case Cachex.get!(:tree_peers, {cluster, tree_hash}) do
      nil -> :ok
      peer -> send(task_pid, {:new_peer, peer})
    end

    state
  end

  def start_search(
        %{
          cluster: cluster,
          target: {ip, port},
          peers_with_conns: peers_with_conns,
          peers: peers
        } = state
      ) do
    n = %{ip: ip, port: port}
    start_conn(cluster, n)

    %{state | peers_with_conns: [n | peers_with_conns], peers: [n | peers]}
  end

  def handle_cast(
        :stop,
        %{active_connections: active_connections} = state
      ) do
    Enum.each(active_connections |> Map.keys(), &ConnectionCache.return/1)
    {:stop, :normal, state}
  end

  def handle_cast(
        {:bad_conn, conn},
        %{active_connections: active_connections} = state
      ) do
    {peer, new_active_connections} = Map.pop(active_connections, conn)

    if not is_nil(peer) do
      send(self(), {:bad_peer, peer})
    end

    {:noreply, %{state | active_connections: new_active_connections}}
  end

  def handle_cast(
        {:has_peer, pid, ref},
        %{waiting_has_peer: waiting_has_peer, peers: peers, target: target} = state
      ) do
    case target do
      t when is_number(t) ->
        if length(peers) >= 1 do
          send(pid, {ref, true})
          {:noreply, state}
        else
          {:noreply, %{state | waiting_has_peer: [{pid, ref} | waiting_has_peer]}}
        end

      _ ->
        send(pid, {ref, true})
        {:noreply, state}
    end
  end

  def handle_cast(
        {:get_connections, pid, ref},
        %{
          waiting_connection: waiting_connection,
          peers_with_conns: peers_with_conns,
          active_connections: active_connections
        } = state
      ) do
    if map_size(active_connections) > 0 do
      send(pid, {ref, active_connections |> Map.keys()})
      {:noreply, state}
    else
      if length(peers_with_conns) == 0 do
        send(pid, {ref, []})
        {:noreply, state}
      else
        {:noreply, %{state | waiting_connection: [{pid, ref} | waiting_connection]}}
      end
    end
  end

  def handle_info(:start, state) do
    {:noreply, start_search(state)}
  end

  def handle_info(
        {:new_conn, peer, conn},
        %{
          target: target,
          cluster: cluster,
          tree_hash: tree_hash,
          waiting_connection: waiting_connection,
          active_connections: active_connections
        } = state
      ) do
    should_save = not is_number(target) or map_size(active_connections) <= target

    Enum.each(waiting_connection, fn {pid, ref} -> send(pid, {ref, [conn]}) end)

    Cachex.put!(:tree_peers, {cluster, tree_hash}, peer)

    if should_save do
      {:noreply,
       %{
         state
         | waiting_connection: [],
           active_connections: Map.put(active_connections, conn, peer)
       }}
    else
      ConnectionCache.return(conn)
      {:noreply, %{state | waiting_connection: []}}
    end
  end

  def handle_info(
        :done,
        %{
          waiting_has_peer: waiting_has_peer,
          waiting_connection: waiting_connection
        } = state
      ) do
    for {pid, ref} <- waiting_connection do
      send(pid, {ref, []})
    end

    for {pid, ref} <- waiting_has_peer do
      send(pid, {ref, false})
    end

    {:noreply, %{state | waiting_has_peer: [], waiting_connection: []}}
  end

  def handle_info(
        {:bad_peer, peer},
        %{
          target: target,
          peers_with_conns: peers_with_conns,
          peers: peers,
          cluster: cluster
        } = state
      ) do
    new_peers = List.delete(peers, peer)
    new_peers_with_conns = List.delete(peers_with_conns, peer)

    if is_number(target) and length(new_peers_with_conns) < target do
      next_peer = Enum.find(new_peers, fn p -> not Enum.member?(peers_with_conns, p) end)

      if next_peer != nil do
        start_conn(cluster, next_peer)
      end

      {:noreply, %{state | peers: new_peers, peers_with_conns: [peer | new_peers_with_conns]}}
    else
      {:noreply, %{state | peers: new_peers, peers_with_conns: [peer | new_peers_with_conns]}}
    end
  end

  def handle_info(
        {:new_peer, peer},
        %{
          cluster: cluster,
          target: target,
          peers_with_conns: peers_with_conns,
          waiting_has_peer: waiting_has_peer,
          peers: peers
        } = state
      ) do
    should_start =
      not is_number(target) or
        (length(peers_with_conns) < target and
           Cachex.get(:blacklisted_ips, {peer.ip, peer.port}) == {:ok, nil})

    if should_start do
      Enum.each(waiting_has_peer, fn {pid, ref} -> send(pid, {ref, true}) end)

      start_conn(cluster, peer)

      {:noreply,
       %{
         state
         | waiting_has_peer: [],
           peers_with_conns: [peer | peers_with_conns],
           peers: [peer | peers]
       }}
    else
      {:noreply, %{state | waiting_has_peer: [], peers: [peer | peers]}}
    end
  end

  def start_conn(cluster, peer) do
    this_pid = self()

    Task.start(fn ->
      case ConnectionCache.get_conn(cluster, peer.ip, peer.port) do
        {:ok, conn} ->
          send(this_pid, {:new_conn, peer, conn})

        {:error, error} ->
          Logger.error("Could not connect to peer #{inspect(peer)} #{to_string(error)}")
          send(this_pid, {:bad_peer, peer})
      end
    end)
  end
end
