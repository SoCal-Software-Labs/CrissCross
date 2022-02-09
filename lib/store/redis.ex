defmodule CrissCross.Store.Redis do
  @moduledoc false

  # `CubDB.Store.Redis` is an implementation of the `Store` protocol

  defstruct conn: nil, prefix: nil
  alias CrissCross.Store.Redis

  @type t :: %Redis{conn: pid, prefix: String.t()}

  def create(redis_opts, prefix) do
    with {:ok, pid} <- Redix.start_link(redis_opts) do
      {:ok, %Redis{conn: pid, prefix: prefix}}
    end
  end
end

defimpl CubDB.Store, for: CrissCross.Store.Redis do
  alias CrissCross.Store.Redis

  def identifier(%Redis{prefix: prefix}) do
    prefix
  end

  def clean_up(_store, cpid, btree) do
    :ok
  end

  def clean_up_old_compaction_files(store, pid) do
    :ok
  end

  def start_cleanup(%Redis{}) do
    {:ok, nil}
  end

  def next_compaction_store(%Redis{}) do
    Store.Redis.create()
  end

  def put_node(%Redis{conn: conn, prefix: prefix}, n) do
    bin = serialize(n)
    loc = :crypto.hash(:blake2b, bin)
    {:ok, "OK"} = Redix.command(conn, ["HMSET", prefix, loc, bin])
    loc
  end

  def put_header(%Redis{conn: conn, prefix: prefix}, header) do
    bin = serialize(header)
    loc = :crypto.hash(:blake2b, bin)
    {:ok, "OK"} = Redix.command(conn, ["HMSET", prefix, loc, bin, "root", loc])
    loc
  end

  def sync(%Redis{}), do: :ok

  def get_node(%Redis{conn: conn, prefix: prefix}, location) do
    case Redix.command(conn, ["HGET", prefix, location]) do
      {:ok, value} -> deserialize(value)
      _ = e -> e
    end
  end

  def get_latest_header(%Redis{conn: conn, prefix: prefix}) do
    case Redix.command(conn, ["HGET", prefix, "root"]) do
      {:ok, nil} ->
        nil

      {:ok, header_loc} ->
        case Redix.command(conn, ["HGET", prefix, header_loc]) do
          {:ok, nil} -> nil
          {:ok, value} when is_binary(value) -> {header_loc, deserialize(value)}
          _ = e -> e
        end

      _ = e ->
        e
    end
  end

  def close(%Redis{conn: conn}) do
    Agent.stop(conn, :normal, :infinity)
  end

  def blank?(%Redis{conn: conn, prefix: prefix}) do
    case Redix.command(conn, ["HGET", prefix, "root"]) do
      {:ok, header_loc} when is_binary(header_loc) -> false
      _ = e -> true
    end
  end

  def open?(%Redis{conn: conn}) do
    Process.alive?(conn)
  end

  defp serialize(d) do
    :erlang.term_to_binary(d)
  end

  defp deserialize(nil), do: nil

  defp deserialize(d) do
    :erlang.binary_to_term(d)
  end
end
