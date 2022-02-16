defmodule CrissCross.Application do
  use Application

  require Logger

  alias CrissCrossDHT.Server.Utils
  import Cachex.Spec

  @cypher "9YtgMwxnoSagovuViBbJ33drDaPpC6Mc2pVDpMLS8erc"
  @public_key "2bDkyNhW9LBRtCsH9xuRRKmvWJtL7QjJ3mao1FkDypmn8kmViGsarw4"

  # "2UPhq1AXgmhSd6etUcSQRPfm42mSREcjUixSgi9N8nU1YoC"
  @cluster_name Utils.encode_human(Utils.hash(Utils.combine_to_sign([@cypher, @public_key])))
  @max_default_overlay_ttl 45 * 60 * 60 * 1000

  @process_name CrissCrossDHT.Server.Worker

  @default_udp 33333

  def start(_type, _args) do
    redis_url = System.get_env("REDIS_URL", "redis://localhost:6379")

    node_id =
      case System.get_env("NODE_SECRET", nil) do
        node_id when is_binary(node_id) ->
          with {:ok, priv} <- Utils.load_private_key(Utils.decode_human!(node_id)),
               {:ok, pub} <- ExSchnorr.public_from_private(priv),
               {:ok, bytes} <- ExSchnorr.public_to_bytes(pub) do
            Utils.hash(bytes)
          else
            {:error, e} ->
              raise "Invalid NODE_SECRET #{inspect(e)}"
          end

        _ ->
          {:ok, redis_conn} = Redix.start_link(redis_url)

          ret =
            case Redix.command(redis_conn, ["GET", "me"]) do
              {:ok, node_id} when is_binary(node_id) ->
                Logger.info("NODE_SECRET not found... loaded ID from storage")
                node_id

              {:ok, nil} ->
                Logger.info("NODE_SECRET not found... generating random ID")
                id = Utils.gen_node_id()
                {:ok, _} = Redix.command(redis_conn, ["SET", "me", id])
                id

              {:error, e} ->
                Logger.error("Redis not working #{inspect(e)}")
                Utils.gen_node_id()
            end

          Redix.stop(redis_conn)
          ret
      end

    CrissCrossDHT.Registry.start()

    bootstrap_overlay =
      System.get_env("BOOTSTRAP_CLUSTER", @cluster_name) |> Utils.decode_human!()

    udp_port = System.get_env("EXTERNAL_UDP_PORT", "#{@default_udp}") |> String.to_integer()
    external_tcp_port = System.get_env("EXTERNAL_TCP_PORT", "22222") |> String.to_integer()
    internal_tcp_port = System.get_env("INTERNAL_TCP_PORT", "11111") |> String.to_integer()

    auth = System.get_env("LOCAL_AUTH", "")
    cluster_dir = System.get_env("CLUSTER_DIR", "./clusters") |> String.trim_trailing("?")
    ip = System.get_env("EXTERNAL_IP", "127.0.0.1")

    [a, b, c, d] =
      ip
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)

    external_ip = {a, b, c, d}

    bootstrap_nodes =
      System.get_env(
        "BOOTSTRAP_NODES",
        "udp://8thbnFn4HZ24vVojR5qV6jsLCoqMaeBAVSxioBLmzGzC@localhost:#{@default_udp}"
      )
      |> String.split(",")
      |> Enum.map(fn c ->
        case URI.parse(c) do
          %URI{scheme: "udp", port: port, host: host, userinfo: userinfo}
          when is_binary(userinfo) ->
            %{node_id: userinfo, host: host, port: port || @default_udp}

          _ ->
            raise "Invalid BOOTSTRAP_NODES config"
        end
      end)

    clusters =
      Path.wildcard("#{cluster_dir}/*.yaml")
      |> Enum.flat_map(fn cluster ->
        case YamlElixir.read_from_string(File.read!(cluster)) do
          {:ok,
           %{
             "Name" => name,
             "MaxTTL" => max_ttl,
             "Cypher" => cypher,
             "PublicKey" => pubk
           } = opts} ->
            [
              {name,
               %{
                 max_ttl: max_ttl,
                 secret: cypher,
                 public_key: pubk,
                 private_key: Map.get(opts, "PrivateKey")
               }}
            ]

          _ ->
            Logger.error("Invalid yaml file #{cluster}")
            []
        end
      end)
      |> Enum.into(%{
        @cluster_name => %{
          max_ttl: @max_default_overlay_ttl,
          secret: @cypher,
          public_key: @public_key
        }
      })

    dht_config = %{
      bootstrap_overlay: bootstrap_overlay,
      port: udp_port,
      ipv4: true,
      ipv4_addr: external_ip,
      ipv6: false,
      clusters: clusters,
      bootstrap_nodes: bootstrap_nodes,
      k_bucket_size: 12,
      storage: {CrissCross.DHTStorage.DHTRedis, [redis_opts: redis_url]},
      process_values_callback: fn cluster, value, ttl ->
        CrissCross.ValueCloner.queue(cluster, value, ttl)
      end
    }

    children = [
      CrissCross.ConnectionCache,
      Supervisor.child_spec(
        {Cachex, name: :blacklisted_ips, expiration: expiration(default: :timer.minutes(10))},
        id: :blacklisted_ips
      ),
      Supervisor.child_spec({Cachex, name: :node_cache}, id: :node_cache),
      {Task.Supervisor, name: CrissCross.TaskSupervisor},
      Supervisor.child_spec(
        {Task, fn -> CrissCross.ExternalRedis.accept(external_tcp_port, redis_url) end},
        restart: :permanent,
        id: :external_redis
      ),
      Supervisor.child_spec(
        {Task,
         fn ->
           CrissCross.InternalRedis.accept(internal_tcp_port, external_tcp_port, redis_url, auth)
         end},
        restart: :permanent,
        id: :internal_redis
      ),
      %{
        start:
          {Agent, :start_link,
           [fn -> Utils.config(dht_config, :clusters) end, [name: CrissCross.ClusterConfigs]]},
        id: CrissCross.ClusterConfigs
      },
      {CrissCross.ValueCloner, {redis_url, external_tcp_port}},
      {CrissCrossDHT.Supervisor, node_id: node_id, worker_name: @process_name, config: dht_config}
    ]

    Logger.info("Exposing IP #{ip}")
    Logger.info("UDP accepting connections on port #{udp_port}")
    ## Start the main supervisor
    opts = [strategy: :one_for_one, name: CrissCross.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
