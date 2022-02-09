defmodule CrissCross.Store.MlDHTStore do
  @moduledoc false

  # `CubDB.Store.MlDHTStore` is an implementation of the `Store` protocol

  defstruct cluster: nil, rsa_priv_key: nil, name: nil, cache: nil
  alias CrissCross.Store.MlDHTStore
  alias MlDHT.Server.Utils

  def create(cluster, private_rsa_key) do
    cache = :ets.new(:asdf, [:set, :public])
    name = Utils.name_from_private_rsa_key(private_rsa_key)
    {:ok, %MlDHTStore{cache: cache, cluster: cluster, rsa_priv_key: private_rsa_key, name: name}}
  end
end

defimpl CubDB.Store, for: CrissCross.Store.MlDHTStore do
  alias CrissCross.Store.MlDHTStore
  alias MlDHT.Server.Utils

  def identifier(%MlDHTStore{name: name}) do
    Utils.encode_human(name)
  end

  def clean_up(_store, cpid, btree) do
    :ok
  end

  def clean_up_old_compaction_files(store, pid) do
    :ok
  end

  def start_cleanup(%MlDHTStore{}) do
    {:ok, nil}
  end

  def next_compaction_store(%MlDHTStore{}) do
    Store.MlDHTStore.create()
  end

  def put_node(%MlDHTStore{cache: cache, cluster: cluster}, n) do
    bin = serialize(n)
    ref = MlDHT.ref()
    loc = Utils.hash(bin)

    task =
      Task.async(fn ->
        {:ok, _} = MlDHT.Registry.register(ref)

        {loc, ref} = MlDHT.store(cluster, bin, -1, ref)
        :ets.insert(cache, {loc, n})

        # MlDHT.find_value_sync(cluster, loc)

        receive do
          {:store_reply, _, ^ref, key} ->
            MlDHT.Registry.unregister(ref)
            key
        after
          10_000 ->
            {:error, :timeout}
        end
      end)

    Task.await(task)
  end

  def put_header(%MlDHTStore{cluster: cluster, rsa_priv_key: rsa_priv_key} = c, header) do
    loc = put_node(c, header)
    ref = MlDHT.ref()

    {:ok, _} = MlDHT.Registry.register(ref)

    if is_binary(loc) do
      {_, ref} = MlDHT.store_name(cluster, rsa_priv_key, loc, -1, ref)
    else
      IO.inspect(loc)
    end

    # loc
    receive do
      {:store_name_reply, _, ^ref, key} ->
        MlDHT.Registry.unregister(ref)
        key
    after
      10_000 ->
        {:error, :timeout}
    end
  end

  def sync(%MlDHTStore{}), do: :ok

  def get_node(%MlDHTStore{cache: cache, cluster: cluster}, location) do
    case :ets.lookup(cache, location) do
      [{_, v}] ->
        v

      _ ->
        case MlDHT.find_value_sync(cluster, location) do
          {_, nil} -> nil
          {_, :not_found} -> nil
          {_, value} when is_binary(value) -> deserialize(value)
          _ = e -> e
        end
    end
  end

  def get_latest_header(%MlDHTStore{cluster: cluster, name: name}) do
    case MlDHT.find_name_sync(cluster, name, 0) do
      {_, nil} ->
        nil

      {_, :not_found} ->
        nil

      {_, header_loc} when is_binary(header_loc) ->
        case MlDHT.find_value_sync(cluster, header_loc, 0) do
          {_, nil} -> nil
          {_, value} when is_binary(value) -> {header_loc, deserialize(value)}
          _ = e -> e
        end

      _ = e ->
        nil
    end
  end

  def close(%MlDHTStore{}) do
    :ok
  end

  def blank?(%MlDHTStore{cluster: cluster, name: name}) do
    case MlDHT.find_name_sync(cluster, name, 0) do
      {:ok, header_loc} when is_binary(header_loc) -> false
      _ = e -> true
    end
  end

  def open?(%MlDHTStore{}) do
    true
  end

  defp serialize(d) do
    :erlang.term_to_binary(d)
  end

  defp deserialize(nil), do: nil

  defp deserialize(d) do
    :erlang.binary_to_term(d)
  end
end
