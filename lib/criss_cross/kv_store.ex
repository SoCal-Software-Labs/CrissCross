defprotocol CrissCross.KVStore do
  @spec put(t, binary, binary) :: :ok
  def put(store, key, value)

  @spec get(t, binary) :: binary | nil
  def get(store, key)

  @spec delete(t, binary) :: binary | nil
  def delete(store, key)
end
