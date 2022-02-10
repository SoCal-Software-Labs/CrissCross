defmodule CrissCross.Store.CachedRPC do
  @moduledoc false

  # `CubDB.Store.CachedRPC` is an implementation of the `Store` protocol

  defstruct conns: nil, local_store: nil, tree_hash: nil
  alias CrissCross.Store.CachedRPC

  def create(conns, tree_hash, local) do
    {:ok, %CachedRPC{conns: conns, tree_hash: tree_hash, local_store: local}}
  end
end

defimpl CubDB.Store, for: CrissCross.Store.CachedRPC do
  alias CrissCross.Store.CachedRPC
  alias CrissCross.Utils

  require Logger

  def identifier(local) do
    local.tree_hash
  end

  def clean_up(_store, cpid, btree) do
    :ok
  end

  def clean_up_old_compaction_files(store, pid) do
    :ok
  end

  def start_cleanup(%CachedRPC{}) do
    {:ok, nil}
  end

  def next_compaction_store(%CachedRPC{}) do
    Store.CachedRPC.create()
  end

  def put_node(%CachedRPC{local_store: local_store}, n) do
    CubDB.Store.put_node(local_store, n)
  end

  def put_header(%CachedRPC{local_store: local_store}, header) do
    CubDB.Store.put_header(local_store, header)
  end

  def sync(%CachedRPC{}), do: :ok

  def get_node(%CachedRPC{conns: conns, local_store: local_store} = rpc, location) do
    case CubDB.Store.get_node(local_store, location) do
      nil ->
        conns
        |> Enum.shuffle()
        |> Enum.reduce_while(nil, fn conn, acc ->
          case Redix.command(conn, ["GET", location]) do
            {:ok, value} when is_binary(value) ->
              v = Utils.deserialize_bert(value)
              put_node(rpc, v)
              {:halt, v}

            {:ok, nil} ->
              {:cont, acc}

            _ = e ->
              Logger.error("Error with remote GET: #{inspect(e)}")
              {:cont, acc}
          end
        end)

      node ->
        node
    end
  end

  def get_latest_header(%CachedRPC{tree_hash: tree_hash, local_store: local_store} = local) do
    case tree_hash do
      nil ->
        nil

      header_loc ->
        case get_node(local, header_loc) do
          nil -> nil
          v -> {header_loc, v}
        end
    end
  end

  def close(%CachedRPC{local_store: local_store}) do
    CubDB.Storage.close(local_store)
  end

  def blank?(%CachedRPC{tree_hash: tree_hash}) do
    tree_hash == nil
  end

  def open?(%CachedRPC{local_store: local_store}) do
    Process.alive?(local_store)
  end
end
