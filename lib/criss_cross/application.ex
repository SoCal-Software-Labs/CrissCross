defmodule CrissCross.Application do
  use Application

  require Logger

  alias CrissCrossDHT.Server.Utils

  @cypher "DEoGUJcJCMKVuHXAmjgNyU6cCrPcHFymd6c7o5i9yVzT"
  @public_key "2bDkyNhW9LBQH3TB1inDAppeHnbwLbpMTGaZ3ZoD5NzpjQRK24uEnLU"
  @private_key "wnpv357S2Qtfv89FiHJAaBiiyPSQF86Vx3cpH5jRF8brjGYfegRW7YhdeaitiQfaBYSRR9VwGPiRoAFACNJ8cYbC8RTMyRshZv"
  @cluster_name Utils.encode_human(Utils.hash(Utils.combine_to_sign([@cypher, @public_key])))

  @process_name CrissCrossDHT.Server.Worker

  @default_udp 35000

  def start(_type, _args) do
    node_id = Utils.gen_node_id()

    CrissCrossDHT.Registry.start()

    external_tcp_port = System.get_env("EXTERNAL_TCP_PORT", "35001") |> String.to_integer()
    internal_tcp_port = System.get_env("INTERNAL_TCP_PORT", "35002") |> String.to_integer()
    redis_url = System.get_env("REDIS_URL", "redis://localhost:6379")
    auth = System.get_env("LOCAL_AUTH", nil)
    cluster_dir = System.get_env("CLUSTER_DIR", "./clusters") |> String.rstrip(?/)

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
          {:ok, %{"Name" => name, "Cypher" => cypher, "PublicKey" => pubk, "PrivateKey" => privk}} ->
            [
              {name,
               %{
                 secret: cypher,
                 public_key: pubk,
                 private_key: privk
               }}
            ]

          _ ->
            Logger.error("Invalid yaml file #{cluster}")
            []
        end
      end)
      |> Enum.into(%{})

    dht_config = %{
      port: System.get_env("EXTERNAL_UDP_PORT", "#{@default_udp}") |> String.to_integer(),
      ipv4: true,
      ipv6: false,
      clusters: clusters,
      bootstrap_nodes: bootstrap_nodes,
      k_bucket_size: 12,
      storage: {CrissCross.DHTStorage.DHTRedis, [redis_opts: redis_url]}
    }

    children = [
      Supervisor.child_spec({Cachex, name: :connection_cache}, id: :connection_cache),
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
      {CrissCrossDHT.Supervisor, node_id: node_id, worker_name: @process_name, config: dht_config}
    ]

    Logger.debug("External serving on: #{external_tcp_port}")
    Logger.debug("Internal serving on: #{internal_tcp_port}")
    ## Start the main supervisor
    opts = [strategy: :one_for_one, name: CrissCross.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
