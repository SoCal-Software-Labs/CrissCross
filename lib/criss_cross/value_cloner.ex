defmodule CrissCross.ValueCloner do
  use GenServer

  alias CubDB.Store
  alias CrissCross.ConnectionCache
  alias CrissCrossDHT.Server.Utils

  require Logger

  @interval 1000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def queue(cluster, hash, ttl) do
    GenServer.cast(__MODULE__, {:queue, cluster, hash, ttl})
  end

  @impl true
  def init({redis_opts, external_port}) do
    {:ok, redis_conn} = Redix.start_link(redis_opts)
    make_store = fn hash -> CrissCross.Store.Local.create(redis_conn, hash, false) end
    Process.send_after(self(), :process_queue, @interval)
    {:ok, %{queue: [], external_port: external_port, make_store: make_store}}
  end

  @impl true
  def handle_info(:process_queue, %{queue: []} = state) do
    Process.send_after(self(), :process_queue, @interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        :process_queue,
        %{queue: [{cluster, tree, ttl} | rest], make_store: make_store} = state
      ) do
    pid = self()

    peers = CrissCross.find_peers_for_header(cluster, tree, 1, [])

    conns =
      Enum.reduce_while(peers, [], fn peer, conns ->
        case ConnectionCache.get_conn(cluster, peer.ip, peer.port) do
          {:ok, conn} ->
            {:cont, [conn | conns]}

          {:error, error} ->
            Logger.error("Could not connect to peer #{inspect(peer)} #{inspect(error)}")
            {:cont, conns}
        end
      end)

    case conns do
      [_ | _] ->
        new_make_store = fn hash ->
          {:ok, store} = state.make_store.(hash)
          CachedRPC.create(conns, hash, store)
        end

        Task.start(fn ->
          Logger.info("Cloning #{Utils.encode_human(cluster)} #{Utils.encode_human(tree)}")

          try do
            {:ok, store} = make_store.(tree)
            :ok = CrissCross.clone(store, make_store)
            :ok = CrissCross.announce(store, cluster, tree, state.external_port, ttl)

            Store.close(store)
            Logger.info("Cloned #{Utils.encode_human(cluster)} #{Utils.encode_human(tree)}")
          after
            send(pid, :process_queue)
          end
        end)

      _ ->
        Logger.error(
          "Could not find peers for #{Utils.encode_human(cluster)} #{Utils.encode_human(tree)}"
        )

        :ok
    end

    {:noreply, %{state | queue: rest}}
  end

  @impl true
  def handle_cast({:queue, cluster, tree, ttl}, %{queue: queue} = state) do
    if Enum.member?(queue, {cluster, tree, ttl}) do
      {:noreply, state}
    else
      {:noreply, %{state | queue: queue ++ [{cluster, tree, ttl}]}}
    end
  end
end
