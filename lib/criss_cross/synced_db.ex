defmodule CrissCross.SyncedDB do
  use GenServer

  def start_link(cluster, public_key, private_key) do
    GenServer.start_link(__MODULE__, [cluster, public_key, private_key], [])
  end

  def init([cluster, public_key, private_key]) do
    local_store = CrissCross.Store.LocalSynced.create(cluster, public_key, private_key)
    {:ok, db} = CubDB.start_link(local_store, auto_file_sync: false, auto_compact: false)
    {:ok, %{db: db}}
  end

  @impl true
  def handle_call({:get_multi, ks}, _from, %{db: db} = state) do
    {:reply, CubDB.get_multi(db, ks), state}
  end

  @impl true
  def handle_cast({:put_multi, kvs}, %{db: db} = state) do
    :ok = CubDB.put_multi(db, kvs)
    {:noreply, state}
  end
end
