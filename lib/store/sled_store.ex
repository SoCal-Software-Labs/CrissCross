defmodule CrissCross.Store.SledStore do
  @moduledoc false

  # `CubDB.Store.SledStore` is an implementation of the `Store` protocol

  defstruct conn: nil, tree_hash_pid: nil, node_count_pid: nil, ttl: nil
  alias CrissCross.Store.SledStore
  import CrissCross.Utils
  alias CrissCross.Utils.MissingHashError

  def create(conn, tree_hash, ttl \\ nil) do
    {:ok, pid} = Agent.start_link(fn -> tree_hash end)

    local = %SledStore{
      conn: conn,
      tree_hash_pid: pid,
      node_count_pid: nil,
      ttl: ttl
    }

    count =
      if is_nil(tree_hash) do
        0
      else
        try do
          case CubDB.Store.get_latest_header(local) do
            {_, {_, {count, _}, _} = n} ->
              count + byte_size(serialize_bert(n))

            _ ->
              raise MissingHashError
          end
        rescue
          MissingHashError ->
            0
        end
      end

    {:ok, ncpid} = Agent.start_link(fn -> count end)
    {:ok, %{local | node_count_pid: ncpid}}
  end
end

defimpl CrissCross.KVStore, for: CrissCross.Store.SledStore do
  alias CrissCross.Store.SledStore

  def put(%SledStore{conn: conn}, key, value) do
    :ok = SortedSetKV.zadd(conn, ".", key, value, nil, true)
  end

  def get(%SledStore{conn: conn}, key) do
    case SortedSetKV.zgetbykey(conn, ".", key, 0) do
      nil -> nil
      {v, _} -> v
    end
  end

  def delete(%SledStore{conn: conn}, key) do
    :ok = SortedSetKV.zrem(conn, ".", key)
  end
end

defimpl CubDB.Store, for: CrissCross.Store.SledStore do
  alias CrissCross.Store.SledStore
  import CrissCross.Utils
  alias CrissCross.Utils.MissingHashError
  require Logger

  defp get_tree_hash(%SledStore{tree_hash_pid: tree_hash_pid}) do
    Agent.get(tree_hash_pid, fn list -> list end)
  end

  def identifier(local) do
    get_tree_hash(local)
  end

  def clean_up(_store, _cpid, _btree) do
    :ok
  end

  def clean_up_old_compaction_files(_store, _pid) do
    :ok
  end

  def start_cleanup(%SledStore{}) do
    {:ok, nil}
  end

  def next_compaction_store(l = %SledStore{}) do
    l
  end

  def put_node(
        %SledStore{conn: conn, node_count_pid: node_count_pid, ttl: ttl},
        n
      ) do
    bin = serialize_bert(n)
    loc = hash(bin, 80)
    count = Agent.get_and_update(node_count_pid, fn count -> {count, count + byte_size(bin)} end)

    if not String.starts_with?(loc, <<0x01>>) do
      case ttl do
        nil ->
          {:ok, _} = Cachex.put(:node_cache, loc, n)

        -1 ->
          {:ok, _} = Cachex.put(:node_cache, loc, n)

          ret = SortedSetKV.zscore(conn, "nodes", loc)

          case ret do
            {false, nil} ->
              :ok = SortedSetKV.zadd(conn, "nodes", loc, bin, 18_446_744_073_709_551_615, true)

            {true, 18_446_744_073_709_551_615} ->
              :ok

            {true, setttl} when is_number(setttl) ->
              :ok = SortedSetKV.zscoreupdate(conn, "nodes", loc, 18_446_744_073_709_551_615, true)
          end

        _ ->
          ttl_diff = ttl - :os.system_time(:millisecond)
          {:ok, _} = Cachex.put(:node_cache, loc, n, ttl: ttl_diff)

          ret = SortedSetKV.zscore(conn, "nodes", loc)

          case ret do
            {false, nil} ->
              :ok = SortedSetKV.zadd(conn, "nodes", loc, bin, ttl, true)

            {true, 18_446_744_073_709_551_615} ->
              :ok

            {true, setttl} when is_number(setttl) and setttl < ttl ->
              :ok = SortedSetKV.zscoreupdate(conn, "nodes", loc, ttl, true)

            {true, setttl} when is_number(setttl) ->
              :ok

            e ->
              raise "Error putting tree node #{inspect(e)}"
          end
      end
    end

    {count, loc}
  end

  def put_header(%SledStore{tree_hash_pid: tree_hash_pid} = local, header) do
    {_, loc} = location = put_node(local, header)
    :ok = Agent.update(tree_hash_pid, fn _list -> loc end)
    location
  end

  def sync(%SledStore{}), do: :ok

  def get_node(
        %SledStore{},
        {_, <<0x01, size::integer-size(8), b::binary-size(size), _::binary>>}
      ) do
    deserialize_bert(b)
  end

  def get_node(%SledStore{conn: conn, ttl: ttl}, {_, loc}) do
    func = fn _ ->
      case SortedSetKV.zgetbykey(conn, "nodes", loc, 0) do
        nil -> {:ignore, nil}
        {value, _} when is_binary(value) -> {:commit, deserialize_bert(value)}
        _ = e -> {:ignore, e}
      end
    end

    cache_func = func

    ret =
      case ttl do
        nil ->
          fetch_from_node_cache(loc, cache_func)

        -1 ->
          ret = SortedSetKV.zscore(conn, "nodes", loc)

          case ret do
            {false, nil} ->
              raise MissingHashError, encode_human(loc)

            {true, nil} ->
              SortedSetKV.zscoreupdate(conn, "nodes", loc, 18_446_744_073_709_551_615, true)
              fetch_from_node_cache(loc, cache_func)

            {true, 18_446_744_073_709_551_615} ->
              fetch_from_node_cache(loc, cache_func)

            {true, setttl} when is_number(setttl) ->
              SortedSetKV.zscoreupdate(conn, "nodes", loc, 18_446_744_073_709_551_615, true)
              fetch_from_node_cache(loc, cache_func)
          end

        _ ->
          ret = SortedSetKV.zscore(conn, "nodes", loc)

          case ret do
            {false, nil} ->
              raise MissingHashError, encode_human(loc)

            {true, nil} ->
              fetch_from_node_cache(loc, cache_func)

            {true, setttl} when is_number(setttl) and setttl < ttl ->
              :ok = SortedSetKV.zscoreupdate(conn, "nodes", loc, ttl, true)
              fetch_from_node_cache(loc, cache_func)

            {true, setttl} when is_number(setttl) ->
              fetch_from_node_cache(loc, cache_func)
          end
      end

    case ret do
      {:error, error} ->
        Logger.error("Error retrieving value from cache: #{inspect(error)}")
        raise MissingHashError, encode_human(loc)

      {_, val} ->
        if is_nil(val) do
          raise MissingHashError, encode_human(loc)
        else
          val
        end
    end
  end

  def get_latest_header(%SledStore{node_count_pid: node_count_pid} = local) do
    case get_tree_hash(local) do
      nil ->
        nil

      header_loc ->
        value = get_node(local, {0, header_loc})

        count =
          if is_nil(node_count_pid) do
            0
          else
            Agent.get(node_count_pid, fn count -> count end)
          end

        {{count, header_loc}, value}
    end
  end

  def close(%SledStore{tree_hash_pid: tree_hash_pid, node_count_pid: node_count_pid}) do
    :ok = Agent.stop(node_count_pid)
    Agent.stop(tree_hash_pid)
  end

  def blank?(local) do
    get_tree_hash(local) == nil
  end

  def open?(%SledStore{tree_hash_pid: tree_hash_pid}) do
    Process.alive?(tree_hash_pid)
  end
end
