defmodule CrissCross.Store.Local do
  @moduledoc false

  # `CubDB.Store.Local` is an implementation of the `Store` protocol

  defstruct conn: nil, tree_hash_pid: nil
  alias CrissCross.Store.Local

  def create(conn, tree_hash) do
    {:ok, pid} = Agent.start_link(fn -> tree_hash end)
    {:ok, %Local{conn: conn, tree_hash_pid: pid}}
  end
end

defimpl CubDB.Store, for: CrissCross.Store.Local do
  alias CrissCross.Store.Local
  alias CrissCross.Utils
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

  def put_node(%Local{conn: conn}, n) do
    bin = Utils.serialize_bert(n)
    loc = CrissCrossDHT.Server.Utils.hash(bin)
    {:ok, _} = Cachex.put(:node_cache, loc, n)
    {:ok, "OK"} = Redix.command(conn, ["SET", "nodes" <> loc, bin])
    loc
  end

  def put_header(%Local{conn: conn, tree_hash_pid: tree_hash_pid}, header) do
    bin = Utils.serialize_bert(header)
    loc = CrissCrossDHT.Server.Utils.hash(bin)
    {:ok, _} = Cachex.put(:node_cache, loc, header)
    {:ok, "OK"} = Redix.command(conn, ["SET", "nodes" <> loc, bin])
    :ok = Agent.update(tree_hash_pid, fn _list -> loc end)
    loc
  end

  def sync(%Local{}), do: :ok

  def get_node(%Local{conn: conn}, location) do
    ret =
      Cachex.fetch(:node_cache, location, fn _ ->
        case Redix.command(conn, ["GET", "nodes" <> location]) do
          {:ok, nil} -> {:ignore, nil}
          {:ok, value} when is_binary(value) -> {:commit, Utils.deserialize_bert(value)}
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

  def get_latest_header(%Local{conn: conn} = local) do
    case get_tree_hash(local) do
      nil ->
        nil

      header_loc ->
        case get_node(local, header_loc) do
          nil -> nil
          value -> {header_loc, value}
        end
    end
  end

  def close(%Local{tree_hash_pid: tree_hash_pid}) do
    Agent.stop(tree_hash_pid)
  end

  def blank?(local) do
    get_tree_hash(local) == nil
  end

  def open?(%Local{tree_hash_pid: tree_hash_pid}) do
    Process.alive?(tree_hash_pid)
  end
end
