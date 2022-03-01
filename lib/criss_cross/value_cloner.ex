defmodule CrissCross.ValueCloner do
  use GenServer

  alias CubDB.Store
  alias CrissCross.PeerGroup
  alias CrissCross.Store.CachedRPC
  alias CrissCrossDHT.Server.Utils
  alias CrissCross.Utils.{MaxTransferExceeded, MissingHashError}
  import CrissCross.Utils, only: [cluster_max_transfer_size: 1]
  require Logger

  @interval 10000
  @max_attempts 5

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def queue(cluster, hash, ttl) do
    GenServer.cast(__MODULE__, {:queue, cluster, hash, ttl, 0})
  end

  @impl true
  def init({make_make_store, external_port}) do
    make_store = make_make_store.()
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
        %{queue: [{cluster, tree, ttl, attempts} | rest], make_store: make_store} = state
      ) do
    pid = self()

    {:ok, peer_group} = PeerGroup.start_link(cluster, 1, tree)

    try do
      if PeerGroup.has_peer(peer_group, 5000) do
        Logger.error(
          "Could not find peers for #{Utils.encode_human(cluster)} #{Utils.encode_human(tree)}"
        )

        if attempts < @max_attempts do
          Logger.info("Putting tree #{Utils.encode_human(tree)} back in queue.")
          Process.send_after(pid, {:queue, cluster, tree, ttl, attempts + 1}, @interval * 2)
        else
          Logger.warning(
            "Max attempts to clone tree #{Utils.encode_human(tree)} for cluster #{Utils.encode_human(cluster)} reached. Quitting."
          )
        end

        send(pid, :process_queue)
        {:noreply, %{state | queue: rest}}
      else
        new_make_store = fn hash ->
          {:ok, store} = make_store.(hash, ttl)
          CachedRPC.create(peer_group, cluster, hash, store)
        end

        Task.start(fn ->
          Logger.info("Cloning #{Utils.encode_human(cluster)} #{Utils.encode_human(tree)}")

          try do
            {:ok, store} = new_make_store.(tree)
            :ok = CrissCross.clone(store, new_make_store)
            max_transfer = cluster_max_transfer_size(cluster)

            case Store.get_latest_header(store) do
              {{written, _}, _} when written > max_transfer ->
                raise MaxTransferExceeded

              _ ->
                :ok
            end

            :ok =
              CrissCross.announce(
                store,
                cluster,
                tree,
                state.external_port,
                ttl - :os.system_time(:millisecond)
              )

            Store.close(store)
            Logger.info("Cloned #{Utils.encode_human(cluster)} #{Utils.encode_human(tree)}")
          rescue
            MaxTransferExceeded ->
              Logger.error(
                "Error cloning #{Utils.encode_human(tree)}: maximum transfer size exceeded."
              )

            MissingHashError ->
              Logger.error(
                "Error cloning #{Utils.encode_human(tree)}: could not find value for node."
              )

              if attempts < @max_attempts do
                Logger.info("Putting tree #{Utils.encode_human(tree)} back in queue.")
                Process.send_after(pid, {:queue, cluster, tree, ttl, attempts + 1}, @interval * 2)
              else
                Logger.warning(
                  "Max attempts to clone tree #{Utils.encode_human(tree)} for cluster #{Utils.encode_human(cluster)} reached. Quitting."
                )
              end
          after
            send(pid, :process_queue)
          end
        end)

        {:noreply, %{state | queue: rest}}
      end
    after
      PeerGroup.stop(pid)
    end
  end

  @impl true
  def handle_cast({:queue, cluster, tree, ttl, attempts}, %{queue: queue} = state) do
    Logger.info("into queue")

    if Enum.member?(queue, {cluster, tree, ttl, attempts}) do
      {:noreply, state}
    else
      {:noreply, %{state | queue: queue ++ [{cluster, tree, ttl, attempts}]}}
    end
  end
end
