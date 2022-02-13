defmodule CrissCross.Store.Local do
  @moduledoc false

  # `CubDB.Store.Local` is an implementation of the `Store` protocol

  defstruct conn: nil, tree_hash_pid: nil, readonly: nil, node_count_pid: nil
  alias CrissCross.Store.Local
  import CrissCross.Utils

  def create(conn, tree_hash, readonly) do
    {:ok, pid} = Agent.start_link(fn -> tree_hash end)

    local = %Local{conn: conn, tree_hash_pid: pid, node_count_pid: nil, readonly: readonly}

    count =
      case CubDB.Store.get_latest_header(local) do
        {_, {_, {count, _}, _} = n} ->
          count + byte_size(serialize_bert(n))

        nil ->
          0
      end

    {:ok, ncpid} = Agent.start_link(fn -> count end)
    {:ok, %{local | node_count_pid: ncpid}}
  end
end

defimpl CubDB.Store, for: CrissCross.Store.Local do
  alias CrissCross.Store.Local
  import CrissCross.Utils
  import Logger

  defp get_tree_hash(%Local{tree_hash_pid: tree_hash_pid}) do
    Agent.get(tree_hash_pid, fn list -> list end)
  end

  def identifier(local) do
    get_tree_hash(local)
  end

  def clean_up(_store, cpid, btree) do
    :ok
  end

  def clean_up_old_compaction_files(store, pid) do
    :ok
  end

  def start_cleanup(%Local{}) do
    {:ok, nil}
  end

  def next_compaction_store(%Local{}) do
    Store.Local.create()
  end

  def put_node(%Local{conn: conn, readonly: readonly, node_count_pid: node_count_pid}, n) do
    bin = serialize_bert(n)
    loc = hash(bin)
    {:ok, _} = Cachex.put(:node_cache, loc, n)
    count = Agent.get_and_update(node_count_pid, fn count -> {count, count + byte_size(bin)} end)

    if not readonly do
      {:ok, "OK"} = Redix.command(conn, ["SET", "nodes" <> loc, bin])
    end

    {count, loc}
  end

  def put_header(%Local{tree_hash_pid: tree_hash_pid} = local, header) do
    {_, loc} = location = put_node(local, header)
    :ok = Agent.update(tree_hash_pid, fn _list -> loc end)
    location
  end

  def sync(%Local{}), do: :ok

  def get_node(%Local{conn: conn}, {_, location}) do
    ret =
      Cachex.fetch(:node_cache, location, fn _ ->
        case Redix.command(conn, ["GET", "nodes" <> location]) do
          {:ok, nil} -> {:ignore, nil}
          {:ok, value} when is_binary(value) -> {:commit, deserialize_bert(value)}
          _ = e -> {:ignore, e}
        end
      end)

    case ret do
      {:error, error} ->
        Logger.error("Error retrieving value from cache: #{inspect(error)}")
        nil

      {_, val} ->
        val
    end
  end

  def get_latest_header(%Local{conn: conn, node_count_pid: node_count_pid} = local) do
    case get_tree_hash(local) do
      nil ->
        nil

      header_loc ->
        case get_node(local, {0, header_loc}) do
          nil ->
            nil

          value ->
            count =
              if is_nil(node_count_pid) do
                0
              else
                Agent.get(node_count_pid, fn count -> count end)
              end

            {{count, header_loc}, value}
        end
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
