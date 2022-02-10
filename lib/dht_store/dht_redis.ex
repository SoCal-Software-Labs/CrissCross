defmodule CrissCross.DHTStorage.DHTRedis do
  @moduledoc false

  use GenServer

  require Logger

  #############
  # Constants #
  #############

  ## One minute in milliseconds
  @min_in_ms 60 * 1000

  ## 5 Minutes
  @review_time 5 * @min_in_ms

  ## 30 Minutes
  @node_expired 30 * @min_in_ms

  def start_link(opts) do
    {redis_opts, opts} = Keyword.pop(opts, :redis_opts)
    {:ok, conn} = Redix.start_link(redis_opts, opts)
    {:ok, _pid} = GenServer.start_link(__MODULE__, [conn], [])
    {:ok, conn}
  end

  def init([conn]) do
    Process.send_after(self(), :review_storage, @review_time)
    {:ok, %{conn: conn}}
  end

  def cluster_announce(pid, cluster, infohash, ttl) do
    expiry = :os.system_time(:millisecond) + ttl

    {:ok, _} =
      Redix.transaction_pipeline(pid, [
        ["ZADD", Enum.join(["announced", cluster], "-"), "GT", "CH", "#{expiry}", infohash]
      ])

    :ok
  end

  def has_announced_cluster(pid, cluster, infohash) do
    ret =
      Redix.transaction_pipeline(pid, [
        ["ZSCORE", Enum.join(["announced", cluster], "-"), infohash]
      ])

    case ret do
      {:ok, nil} -> false
      {:ok, _} -> true
      e -> e
    end
  end

  def put(pid, cluster, infohash, ip, port, ttl) do
    expiry = :os.system_time(:millisecond) + ttl
    bin = :erlang.term_to_binary({ip, port})

    {:ok, _} =
      Redix.transaction_pipeline(pid, [
        ["ZADD", Enum.join(["members", cluster, infohash], "-"), "CH", "#{expiry}", bin]
      ])

    :ok
  end

  def put_value(pid, _cluster, key, value, ttl) do
    {:ok, _} =
      case ttl do
        -1 ->
          Redix.transaction_pipeline(pid, [["SET", "values" <> key, value]])

        _ ->
          Redix.transaction_pipeline(pid, [
            ["SET", "values" <> key, value],
            ["EXPIRE", key, "#{div(ttl, 1000)}"]
          ])
      end

    :ok
  end

  def put_name(pid, cluster, name, value, generation, signature, ttl) do
    bin = :erlang.term_to_binary({value, generation, signature})
    key = Enum.join(["names", cluster, name], "-")

    {:ok, _} =
      case ttl do
        -1 ->
          Redix.transaction_pipeline(pid, [["SET", key, bin]])

        _ ->
          Redix.transaction_pipeline(pid, [
            ["SET", key, bin],
            ["EXPIRE", key, "#{div(ttl, 1000)}"]
          ])
      end

    :ok
  end

  def has_nodes_for_infohash?(pid, cluster, infohash) do
    {:ok, exists} =
      Redix.command(pid, [
        "ZCOUNT",
        Enum.join(["members", cluster, infohash], "-"),
        "#{:os.system_time(:millisecond)}",
        "+inf"
      ])

    exists > 0
  end

  def get_nodes(pid, cluster, infohash) do
    {:ok, vals} =
      Redix.command(pid, [
        "ZRANGEBYSCORE",
        Enum.join(["members", cluster, infohash], "-"),
        "#{:os.system_time(:millisecond)}",
        "+inf"
      ])

    vals |> Enum.map(&:erlang.binary_to_term/1)
  end

  def get_value(pid, _cluster, infohash) do
    {:ok, val} = Redix.command(pid, ["GET", "values" <> infohash])
    val
  end

  def get_name(pid, cluster, infohash) do
    {:ok, val} = Redix.command(pid, ["GET", Enum.join(["names", cluster, infohash], "-")])

    case val do
      nil -> nil
      v -> :erlang.binary_to_term(v)
    end
  end

  def handle_info(:review_storage, %{conn: conn} = state) do
    Logger.debug("Review storage")

    ## Restart review timer
    Process.send_after(self(), :review_storage, @review_time)

    :ok = scan_keys(conn, "0")
    :ok = scan_announce(conn, "0")

    {:noreply, state}
  end

  def scan_keys(conn, agg) do
    {:ok, [new_agg, infohashes]} =
      Redix.command(conn, [
        "SCAN",
        agg,
        "MATCH",
        "members-*"
      ])

    for key <- infohashes do
      {:ok, _val} =
        Redix.command(conn, [
          "ZREMRANGEBYSCORE",
          key,
          "-inf",
          "(#{:os.system_time(:millisecond)}"
        ])
    end

    case new_agg do
      "0" -> :ok
      _ -> scan_keys(conn, new_agg)
    end
  end

  def scan_announce(conn, agg) do
    {:ok, [new_agg, infohashes]} =
      Redix.command(conn, [
        "SCAN",
        agg,
        "MATCH",
        "announced-*"
      ])

    for key <- infohashes do
      {:ok, _val} =
        Redix.command(conn, [
          "ZREMRANGEBYSCORE",
          key,
          "-inf",
          "(#{:os.system_time(:millisecond)}"
        ])
    end

    case new_agg do
      "0" -> :ok
      _ -> scan_announce(conn, new_agg)
    end
  end
end
