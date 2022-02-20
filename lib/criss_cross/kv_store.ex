defprotocol CrissCross.KVStore do
  @moduledoc false

  # The `CubDB.Store` protocol defines the storage interface for CubDB. It
  # provides functions to read and write nodes and headers, locate the latest
  # header, and managing durability.

  alias CubDB.Btree

  @spec put(t, binary, binary) :: :ok
  def put(store, key, value)

  @spec get(t, binary) :: binary | nil
  def get(store, key)
  @spec delete(t, binary) :: binary | nil
  def delete(store, key)
end
