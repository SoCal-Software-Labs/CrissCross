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
    IO.inspect("DHTRedis")
    {redis_opts, opts} = Keyword.pop(opts, :redis_opts)
    {:ok, conn} = Redix.start_link(redis_opts, opts)
    {:ok, _pid} = GenServer.start_link(__MODULE__, [conn], [])
    {:ok, conn}
  end

  def init([conn]) do
    Process.send_after(self(), :review_storage, @review_time)
    {:ok, %{conn: conn}}
  end

  def put(pid, infohash, ip, port) do
    expiry = :os.system_time(:millisecond) + @node_expired
    bin = :erlang.term_to_binary({ip, port})

    {:ok, _} =
      Redix.transaction_pipeline(pid, [["ZADD", "members" <> infohash, "#{expiry}", bin]])

    :ok
  end

  def put_value(pid, key, value, ttl) do
    {:ok, _} =
      case ttl do
        -1 ->
          Redix.transaction_pipeline(pid, [["SET", "values" <> key, value]])

        _ ->
          Redix.transaction_pipeline(pid, [
            ["SET", "values" <> key, value],
            ["EXPIRE", "mykey", "#{div(ttl, 1000)}"]
          ])
      end

    :ok
  end

  def put_name(pid, name, value, generation, signature, ttl) do
    bin = :erlang.term_to_binary({value, generation, signature})

    {:ok, _} =
      case ttl do
        -1 ->
          Redix.transaction_pipeline(pid, [["SET", "names" <> name, bin]])

        _ ->
          Redix.transaction_pipeline(pid, [
            ["SET", "names" <> name, bin],
            ["EXPIRE", "mykey", "#{div(ttl, 1000)}"]
          ])
      end

    :ok
  end

  def has_nodes_for_infohash?(pid, infohash) do
    {:ok, exists} =
      Redix.command(pid, [
        "ZCOUNT",
        "members" <> infohash,
        "#{:os.system_time(:millisecond)}",
        "+inf"
      ])

    exists > 0
  end

  def get_nodes(pid, infohash) do
    {:ok, vals} =
      Redix.command(pid, [
        "ZRANGEBYSCORE",
        "members" <> infohash,
        "#{:os.system_time(:millisecond)}",
        "+inf"
      ])

    vals
  end

  def get_value(pid, infohash) do
    {:ok, val} = Redix.command(pid, ["GET", "values" <> infohash])
    val
  end

  def get_name(pid, infohash) do
    {:ok, val} = Redix.command(pid, ["GET", "names" <> infohash])

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

    {:noreply, state}
  end

  def scan_keys(conn, agg) do
    {:ok, [new_agg, infohashes]} =
      Redix.command(conn, [
        "SCAN",
        agg,
        "MATCH",
        "members*"
      ])

    for infohash <- infohashes do
      {:ok, _val} =
        Redix.command(conn, [
          "ZREMRANGEBYSCORE",
          "members" <> infohash,
          "-inf",
          "(#{:os.system_time(:millisecond)}"
        ])
    end

    case new_agg do
      "0" -> :ok
      _ -> scan_keys(conn, new_agg)
    end
  end
end
