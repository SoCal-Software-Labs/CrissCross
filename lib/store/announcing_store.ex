defmodule CrissCross.Store.AnnouncingStore do
  @moduledoc false

  # `CubDB.Store.AnnouncingStore` is an implementation of the `Store` protocol

  defstruct cluster: nil, ttl: nil, local_store: nil, tree_hash: nil
  alias CrissCross.Store.AnnouncingStore

  def create(cluster, ttl, local) do
    {:ok, %AnnouncingStore{cluster: cluster, ttl: ttl, local_store: local}}
  end
end

defimpl CubDB.Store, for: CrissCross.Store.AnnouncingStore do
  alias CrissCross.Store.AnnouncingStore
  alias CrissCross.Utils

  def identifier(%AnnouncingStore{local_store: local_store}) do
    CubDB.Store.identifier(local_store)
  end

  def clean_up(_store, cpid, btree) do
    :ok
  end

  def clean_up_old_compaction_files(store, pid) do
    :ok
  end

  def start_cleanup(%AnnouncingStore{}) do
    {:ok, nil}
  end

  def next_compaction_store(%AnnouncingStore{}) do
    Store.AnnouncingStore.create()
  end

  def put_node(%AnnouncingStore{local_store: local_store}, n) do
    CubDB.Store.put_node(local_store, n)
  end

  def put_header(%AnnouncingStore{local_store: local_store}, header) do
    CubDB.Store.put_header(local_store, header)
  end

  def sync(%AnnouncingStore{}), do: :ok

  def get_node(
        %AnnouncingStore{cluster: cluster, ttl: ttl, local_store: local_store} = rpc,
        location
      ) do
    case CubDB.Store.get_node(local_store, location) do
      nil ->
        nil

      node ->
        CrissCrossDHT.cluster_announce(cluster, location, ttl)
        node
    end
  end

  def get_latest_header(
        %AnnouncingStore{cluster: cluster, ttl: ttl, local_store: local_store} = local
      ) do
    case CubDB.Store.get_latest_header(local_store) do
      nil ->
        nil

      {{_, location}, header} = e ->
        CrissCrossDHT.cluster_announce(cluster, location, ttl)
        e
    end
  end

  def close(%AnnouncingStore{local_store: local_store}) do
    CubDB.Storage.close(local_store)
  end

  def blank?(%AnnouncingStore{local_store: local_store}) do
    CubDB.Storage.blank?(local_store)
  end

  def open?(%AnnouncingStore{local_store: local_store}) do
    Process.alive?(local_store)
  end
end
