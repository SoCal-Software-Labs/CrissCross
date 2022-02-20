defmodule CrissCross.Store.Local do
  @moduledoc false

  # `CubDB.Store.Local` is an implementation of the `Store` protocol

  defstruct conn: nil, tree_hash_pid: nil, node_count_pid: nil, ttl: nil
  alias CrissCross.Store.Local
  import CrissCross.Utils
  alias CrissCross.Utils.MissingHashError

  def create(conn, tree_hash, ttl \\ nil) do
    {:ok, pid} = Agent.start_link(fn -> tree_hash end)

    local = %Local{
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

defimpl CrissCross.KVStore, for: CrissCross.Store.Local do
  alias CrissCross.Store.Local

  def put(%Local{conn: conn}, key, value) do
    {:ok, "OK"} = Redix.command(conn, ["SET", key, value])
    :ok
  end

  def get(%Local{conn: conn, node_count_pid: node_count_pid, ttl: ttl}, key) do
    {:ok, v} = Redix.command(conn, ["GET", key])
    v
  end

  def delete(%Local{conn: conn, node_count_pid: node_count_pid, ttl: ttl}, key) do
    {:ok, _} = Redix.command(conn, ["DEL", key])
    :ok
  end
end

defimpl CubDB.Store, for: CrissCross.Store.Local do
  alias CrissCross.Store.Local
  import CrissCross.Utils
  alias CrissCross.Utils.MissingHashError
  require Logger

  defp get_tree_hash(%Local{tree_hash_pid: tree_hash_pid}) do
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

  def start_cleanup(%Local{}) do
    {:ok, nil}
  end

  def next_compaction_store(l = %Local{}) do
    l
  end

  def put_node(
        %Local{conn: conn, node_count_pid: node_count_pid, ttl: ttl},
        n
      ) do
    bin = serialize_bert(n)
    loc = hash(bin)
    count = Agent.get_and_update(node_count_pid, fn count -> {count, count + byte_size(bin)} end)
    key = "nodes" <> loc

    if not String.starts_with?(loc, <<0x01>>) do
      case ttl do
        nil ->
          {:ok, _} = Cachex.put(:node_cache, loc, n)

        -1 ->
          {:ok, _} = Cachex.put(:node_cache, loc, n)

          {:ok, ret} =
            Redix.command(
              conn,
              ["PTTL", key]
            )

          # Until Redis 7 is released make sure TTLs are monotonic
          case ret do
            -2 ->
              {:ok, "OK"} = Redix.command(conn, ["SET", key, bin])

            -1 ->
              :ok

            setttl when is_number(setttl) ->
              {:ok, "OK"} = Redix.command(conn, ["PERSIST", key])
          end

        _ ->
          ttl_diff = ttl - :os.system_time(:millisecond)
          {:ok, _} = Cachex.put(:node_cache, loc, n, ttl: ttl_diff)

          # Until Redis 7 is released make sure TTLs are monotonic
          {:ok, ret} =
            Redix.command(
              conn,
              ["PTTL", key]
            )

          case ret do
            -2 ->
              {:ok, "OK"} =
                Redix.command(
                  conn,
                  ["SET", key, bin, "PXAT", "#{ttl}"]
                )

            -1 ->
              :ok

            setttl when is_number(setttl) and setttl < ttl_diff ->
              {:ok, 1} =
                Redix.command(
                  conn,
                  ["PEXPIREAT", key, "#{ttl}"]
                )

            setttl when is_number(setttl) ->
              :ok

            e ->
              raise "Error putting tree node #{inspect(e)}"
          end
      end
    end

    {count, loc}
  end

  def put_header(%Local{tree_hash_pid: tree_hash_pid} = local, header) do
    {_, loc} = location = put_node(local, header)
    :ok = Agent.update(tree_hash_pid, fn _list -> loc end)
    location
  end

  def sync(%Local{}), do: :ok

  def get_node(
        %Local{},
        {_, <<0x01, _::integer-size(8), size::integer-size(8), b::binary-size(size), _::binary>>}
      ) do
    deserialize_bert(b)
  end

  def get_node(%Local{conn: conn, ttl: ttl}, {_, location}) do
    key = "nodes" <> location

    func = fn expire_command ->
      case Redix.pipeline(conn, [["GET", key]] ++ expire_command) do
        {:ok, [nil | _]} -> {:ignore, nil}
        {:ok, [value | _]} when is_binary(value) -> {:commit, deserialize_bert(value)}
        _ = e -> {:ignore, e}
      end
    end

    cache_func = fn _ -> func.([]) end

    ret =
      case ttl do
        nil ->
          fetch_from_node_cache(location, cache_func)

        -1 ->
          {:ok, ret} =
            Redix.command(
              conn,
              ["PTTL", key]
            )

          case ret do
            -2 ->
              raise MissingHashError, encode_human(location)

            -1 ->
              fetch_from_node_cache(location, cache_func)

            setttl when is_number(setttl) ->
              func.(["PERSIST", key])
          end

        _ ->
          ttl_diff = ttl - :os.system_time(:millisecond)

          {:ok, ret} =
            Redix.command(
              conn,
              ["PTTL", key]
            )

          case ret do
            -2 ->
              raise MissingHashError, encode_human(location)

            -1 ->
              fetch_from_node_cache(location, cache_func)

            setttl when is_number(setttl) and setttl < ttl_diff ->
              func.(["PEXPIREAT", key, "#{ttl}"])

            setttl when is_number(setttl) ->
              fetch_from_node_cache(location, cache_func)
          end
      end

    case ret do
      {:error, error} ->
        Logger.error("Error retrieving value from cache: #{inspect(error)}")
        raise MissingHashError, encode_human(location)

      {_, val} ->
        if is_nil(val) do
          raise MissingHashError, encode_human(location)
        else
          val
        end
    end
  end

  def get_latest_header(%Local{node_count_pid: node_count_pid} = local) do
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

  def close(%Local{tree_hash_pid: tree_hash_pid, node_count_pid: node_count_pid}) do
    :ok = Agent.stop(node_count_pid)
    Agent.stop(tree_hash_pid)
  end

  def blank?(local) do
    get_tree_hash(local) == nil
  end

  def open?(%Local{tree_hash_pid: tree_hash_pid}) do
    Process.alive?(tree_hash_pid)
  end
end
