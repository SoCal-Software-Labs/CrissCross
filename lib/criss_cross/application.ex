defmodule CrissCross.Application do
  use Application

  require Logger

  alias CrissCrossDHT.Server.Utils
  import Cachex.Spec

  @cluster_name "2UPm6jo6SNfDQwc8Xa5BgBqw6NNubP3eqexN57oNwdxV3md"

  @process_name CrissCrossDHT.Server.Worker

  @default_udp 22222

  @default_bootstrap "quic://5owBehSAPoSLBgKdeMZR9X9tKsgAqBHWrLxif6ZP7vrJ2BmUYbKn7mhB8Z@bootstrap.cxn.cx:22222"

  def convert_ip(var, default) do
    ip_to_bind = System.get_env(var, default)

    {:ok, addr} = :inet.parse_address(String.to_charlist(ip_to_bind))

    {ip_to_bind, addr}
  end

  def bootstrap_nodes() do
    System.get_env(
      "BOOTSTRAP_NODES",
      @default_bootstrap
    )
    |> String.split(",")
    |> Enum.filter(fn c -> c != "" end)
    |> Enum.map(fn c ->
      case URI.parse(c) do
        %URI{scheme: "quic", port: port, host: host, userinfo: userinfo}
        when is_binary(userinfo) ->
          %{node_id: userinfo, host: host, port: port || @default_udp}

        _ ->
          raise "Invalid BOOTSTRAP_NODES config"
      end
    end)
  end

  def node_id(store) do
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
        ret =
          case CrissCross.KVStore.get(store, "me") do
            node_id when is_binary(node_id) ->
              Logger.info("NODE_SECRET not found... loaded ID from storage")
              node_id

            nil ->
              Logger.info("NODE_SECRET not found... generating random ID")
              id = Utils.gen_node_id()
              :ok = CrissCross.KVStore.put(store, "me", id)
              id

            e ->
              Logger.error("Storage backend not working #{inspect(e)}")
              Utils.gen_node_id()
          end

        ret
    end
  end

  def get_backends(storage_backend) do
    Logger.info("Setting up storage: #{storage_backend}")

    case URI.parse(storage_backend) do
      %URI{scheme: "sled", host: host, path: path} ->
        Logger.info("Opening DB: #{Path.expand("#{host}#{path}")}")
        {:ok, db} = SortedSetKV.open(Path.expand("#{host}#{path}"))
        storage = {CrissCrossDHT.Server.DHTSled, [database: db]}

        make_make_store = fn ->
          fn hash, ttl -> CrissCross.Store.SledStore.create(db, hash, ttl) end
        end

        {storage, make_make_store}

      # %URI{scheme: "redis"} ->
      #   storage = {CrissCrossDHT.Server.DHTRedis, [redis_opts: storage_backend]}

      #   make_make_store = fn ->
      #     {:ok, redis_conn} = Redix.start_link(storage_backend)
      #     fn hash, ttl -> CrissCross.Store.Local.create(redis_conn, hash, ttl) end
      #   end

      #   {storage, make_make_store}

      _ ->
        raise "Invalid STORAGE_BACKEND config"
    end
  end

  def start(_type, _args) do
    :inets.start()
    :ssl.start()

    storage_backend = System.get_env("STORAGE_BACKEND", "sled://./data")

    CrissCrossDHT.Registry.start()

    bootstrap_overlay =
      System.get_env("BOOTSTRAP_CLUSTER", @cluster_name) |> Utils.decode_human!()

    external_port = System.get_env("EXTERNAL_PORT", "#{@default_udp}") |> String.to_integer()
    internal_tcp_port = System.get_env("INTERNAL_TCP_PORT", "11111") |> String.to_integer()

    auth = System.get_env("LOCAL_AUTH", "")
    tunnel_token = System.get_env("TUNNEL_TOKEN")

    cluster_dir =
      System.get_env("CLUSTER_DIR", "./clusters") |> String.trim_trailing("?") |> Path.expand()

    name_dir = System.get_env("KEY_DIR", "./keys") |> String.trim_trailing("?") |> Path.expand()

    # {ip, external_ip} = convert_ip("EXTERNAL_IP", "127.0.0.1")
    {ip_to_bind, bind_ip} = convert_ip("BIND_IP", "127.0.0.1")

    bootstrap_nodes = bootstrap_nodes()

    bootstrap_nodes_for_endpoint =
      bootstrap_nodes
      |> Enum.map(fn %{host: ip, port: port, node_id: node_id} ->
        {node_id, ip, port}
      end)
      |> Utils.resolve_hostnames(:inet6)
      |> Enum.map(fn {_, host, port} -> Utils.tuple_to_ipstr(host, port) end)

    {storage, make_make_store} = get_backends(storage_backend)

    # Shared storage for meta data
    {:ok, store} = make_make_store.().(nil, nil)
    node_id = node_id(store)

    dht_config = %{
      bootstrap_overlay: bootstrap_overlay,
      port: external_port,
      # ipv4_addr: external_ip,
      dispatcher: ExP2P.Dispatcher,
      bind_ip: bind_ip,
      cluster_dir: cluster_dir,
      name_dir: name_dir,
      bootstrap_nodes: bootstrap_nodes,
      k_bucket_size: 12,
      storage: storage,
      process_values_callback: fn cluster, value, ttl ->
        CrissCross.ValueCloner.queue(cluster, value, ttl)
      end
    }

    dispatcher_callback = fn endpoint, _connection, msg, sender, from, state ->
      {l, r} =
        case from do
          "[" <> rest ->
            [l, r] = String.split(rest, "]:", parts: 2)
            {l, r}

          _ ->
            [l, r] = String.split(from, ":", parts: 2)
            {l, r}
        end

      {:ok, addr} = :inet.parse_address(String.to_charlist(l))

      if is_nil(sender) do
        send(@process_name, {:udp, endpoint, addr, String.to_integer(r), msg})
      else
        CrissCross.CommandQueue.handle_new_message(msg, sender, from, endpoint, store, state)
      end

      :ok
    end

    children = [
      CrissCross.ProcessQueue,
      {CrissCross.VPNConfig, [[]]},
      {Registry, keys: :unique, name: CrissCross.VPNRegistry},
      {Registry, keys: :unique, name: CrissCross.VPNClientRegistry},
      {ExP2P.Dispatcher,
       bind_addr: Utils.tuple_to_ipstr(bind_ip, external_port),
       bootstrap_nodes: bootstrap_nodes_for_endpoint,
       connection_mod: ExP2P.Connection,
       connection_mod_args: %{
         new_state: &CrissCross.CommandQueue.new_state/1,
         callback: dispatcher_callback
       },
       opts: [name: ExP2P.Dispatcher]},
      CrissCross.ConnectionCache,
      {Registry, keys: :duplicate, name: CrissCross.ConnectionRegistry},
      Supervisor.child_spec(
        {Cachex, name: :local_jobs},
        id: :local_jobs
      ),
      Supervisor.child_spec(
        {Cachex, name: :cached_vars, expiration: expiration(default: :timer.seconds(5))},
        id: :cached_vars
      ),
      Supervisor.child_spec(
        {Cachex, name: :pids, expiration: expiration(default: :timer.minutes(10))},
        id: :pids
      ),
      Supervisor.child_spec(
        {Cachex, name: :tree_peers, expiration: expiration(default: :timer.minutes(1))},
        id: :tree_peers
      ),
      Supervisor.child_spec(
        {Cachex, name: :blacklisted_ips, expiration: expiration(default: :timer.seconds(5))},
        id: :blacklisted_ips
      ),
      Supervisor.child_spec(
        {Cachex, name: :waiting_streams, expiration: expiration(default: :timer.minutes(1))},
        id: :waiting_streams
      ),
      Supervisor.child_spec(
        {Cachex,
         name: :node_cache, limit: limit(size: 1000, policy: Cachex.Policy.LRW, reclaim: 0.1)},
        id: :node_cache
      ),
      {Task.Supervisor, name: CrissCross.TaskSupervisor},
      # Supervisor.child_spec(
      #   {Task, fn -> CrissCross.ExternalRedis.accept(external_tcp_port, make_make_store) end},
      #   restart: :permanent,
      #   id: :external_redis
      # ),
      Supervisor.child_spec(
        {Task,
         fn ->
           CrissCross.InternalRedis.accept(
             internal_tcp_port,
             external_port,
             make_make_store,
             store,
             auth,
             tunnel_token
           )
         end},
        restart: :permanent,
        id: :internal_redis
      ),
      {CrissCross.ValueCloner, {make_make_store, external_port}},
      {CrissCrossDHT.Supervisor, node_id: node_id, worker_name: @process_name, config: dht_config}
    ]

    Logger.info("Binding on #{ip_to_bind}")
    Logger.info("Trying to contact bootstrap nodes...")

    ## Start the main supervisor
    opts = [strategy: :one_for_one, name: CrissCross.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
