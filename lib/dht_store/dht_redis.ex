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

  ## 60 Minutes
  @node_reannounce 1000 * 60 * @min_in_ms

  def start_link(opts) do
    {redis_opts, opts} = Keyword.pop(opts, :redis_opts)
    {:ok, conn} = Redix.start_link(redis_opts, opts)

    case Redix.command(conn, ["PING"]) do
      {:ok, "PONG"} ->
        {:ok, _pid} = GenServer.start_link(__MODULE__, [conn], [])
        {:ok, conn}

      e ->
        e
    end
  end

  def init([conn]) do
    Process.send_after(self(), :review_storage, @review_time)
    {:ok, %{conn: conn}}
  end

  def cluster_announce(pid, cluster, infohash, ttl) do
    ttl =
      if ttl == -1 do
        "+inf"
      else
        ttl
      end

    {:ok, _} =
      Redix.command(
        pid,
        ["ZADD", Enum.join(["announced", cluster], "-"), "GT", "CH", "#{ttl}", infohash]
      )

    :ok
  end

  def has_announced_cluster(pid, cluster, infohash) do
    ret =
      Redix.command(
        pid,
        ["ZSCORE", Enum.join(["announced", cluster], "-"), infohash]
      )

    case ret do
      {:ok, nil} -> false
      {:ok, _} -> true
      e -> e
    end
  end

  def put(pid, cluster, infohash, ip, port, ttl) do
    bin = :erlang.term_to_binary({ip, port})

    {:ok, _} =
      Redix.command(
        pid,
        ["ZADD", Enum.join(["members", cluster, infohash], "-"), "CH", "#{ttl}", bin]
      )

    :ok
  end

  def put_value(pid, cluster, key, value, ttl) do
    bin = :erlang.term_to_binary({cluster, key, ttl})

    {:ok, _} =
      case ttl do
        -1 ->
          Redix.transaction_pipeline(pid, [
            ["SET", Enum.join(["values", cluster, key], "-"), value],
            ["RPUSH", "values:queue", bin]
          ])

        _ ->
          Redix.transaction_pipeline(pid, [
            ["SET", Enum.join(["values", cluster, key], "-"), value, "PXAT", "#{ttl}"],
            ["RPUSH", "values:queue", bin]
          ])
      end

    :ok
  end

  def put_name(
        pid,
        cluster,
        name,
        value,
        generation,
        public_key,
        signature_cluster,
        signature,
        ttl
      ) do
    bin =
      :erlang.term_to_binary({value, generation, ttl, public_key, signature_cluster, signature})

    key = Enum.join(["names", cluster, name], "-")
    next_time = :os.system_time(:millisecond) + @node_reannounce + :rand.uniform(@node_reannounce)

    reannounce =
      if ttl == -1 or ttl > next_time do
        bin = :erlang.term_to_binary({cluster, name})
        [["ZADD", "nameclock", "CH", "#{next_time}", bin]]
      else
        []
      end

    {:ok, _} =
      case ttl do
        -1 ->
          Redix.transaction_pipeline(pid, [["SET", key, bin]] ++ reannounce)

        _ ->
          Redix.transaction_pipeline(
            pid,
            [
              ["SET", key, bin, "PXAT", "#{ttl}"]
            ] ++ reannounce
          )
      end

    :ok
  end

  def refresh_name(pid, cluster, name) do
    bin = :erlang.term_to_binary({cluster, name})
    now = :os.system_time(:millisecond)
    next_time = now + @node_reannounce + :rand.uniform(@node_reannounce)
    {:ok, _} = Redix.command(pid, ["ZADD", "nameclock", "CH", "#{next_time}", bin])
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
        "+inf",
        "LIMIT",
        "0",
        "100"
      ])

    vals |> Enum.map(&:erlang.binary_to_term/1)
  end

  def get_value(pid, cluster, infohash) do
    {:ok, val} = Redix.command(pid, ["GET", Enum.join(["values", cluster, infohash], "-")])
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

  def process_values(conn, callback) do
    {:ok, next_value} =
      Redix.command(conn, [
        "LPOP",
        "values:queue"
      ])

    case next_value do
      bin when is_binary(bin) ->
        {cluster, hash, ttl} = :erlang.binary_to_term(bin)

        case Redix.command(conn, ["GET", Enum.join(["values", cluster, hash], "-")]) do
          {:ok, val} when is_binary(val) ->
            :ok = callback.(cluster, val, ttl)
            process_values(conn, callback)

          _ ->
            :ok
        end

      nil ->
        :ok
    end
  end

  def reannounce_names(conn, worker_pid) do
    now = :os.system_time(:millisecond)

    {:ok, infohashes} =
      Redix.command(conn, [
        "ZRANGE",
        "nameclock",
        "-inf",
        "(#{now}",
        "BYSCORE"
      ])

    for bin <- infohashes do
      {cluster, name} = :erlang.binary_to_term(bin)
      key = Enum.join(["names", cluster, name], "-")

      case Redix.command(conn, ["GET", key]) do
        {:ok, b} when is_binary(b) ->
          {value, generation, ttl, public_key, signature_cluster, signature_name} =
            :erlang.binary_to_term(b)

          tid = KRPCProtocol.gen_tid()

          Logger.debug(
            "Reannouncing #{CrissCrossDHT.Server.Utils.encode_human(cluster)} #{CrissCrossDHT.Server.Utils.encode_human(name)}"
          )

          GenServer.cast(
            worker_pid,
            {:broadcast_name, cluster, tid, name, value, ttl, public_key, generation,
             signature_cluster, signature_name}
          )

          if ttl > now do
            refresh_name(conn, cluster, name)
          end

        _ ->
          :ok
      end
    end

    {:ok, _} =
      Redix.command(conn, [
        "ZREMRANGEBYSCORE",
        "nameclock",
        "-inf",
        "(#{:os.system_time(:millisecond)}"
      ])
  end
end
