defmodule CrissCross.InternalRedis do
  require Logger

  import CrissCross.Utils

  alias CrissCross.Utils.{
    MissingHashError,
    DecoderError,
    HTTPResolutionError,
    DNSResolutionError,
    MissingVarError,
    MulticodecError
  }

  alias CubDB.Store
  alias CrissCross.KVStore
  alias CrissCross.Scanner
  alias CrissCross.ConnectionCache
  alias CrissCross.Store.CachedRPC
  alias CrissCrossDHT.Server.Utils, as: DHTUtils
  alias CrissCross.PeerGroup

  @max_peer_tries 3
  @read_commands [
    "GETMULTIBIN",
    "GETMULTI",
    "FETCH",
    "FETCHBIN",
    "HASKEY",
    "HASKEYBIN",
    "SQL",
    "SQLJSON",
    "ITERSTART",
    "PERSIST",
    "COMPACT",
    "BYTESWRITTEN"
  ]

  def accept(port, external_port, make_make_store, store, auth, tunnel_token) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, active: true, reuseaddr: true])
    Logger.info("Internal TCP accepting connections on port #{port}")

    make_store = make_make_store.()

    loop_acceptor(socket, %{
      auth: auth,
      iterator: nil,
      authed: false,
      external_port: external_port,
      store: store,
      make_store: make_store,
      tunnel_token: tunnel_token
    })
  end

  defp loop_acceptor(socket, state) do
    {:ok, client} = :gen_tcp.accept(socket)

    {:ok, pid} =
      Task.Supervisor.start_child(CrissCross.TaskSupervisor, fn ->
        serve(
          client,
          %{continuation: nil},
          Map.merge(state, %{socket: client, streams: %{}, subscriptions: %{}})
        )
      end)

    :ok = :gen_tcp.controlling_process(client, pid)

    loop_acceptor(socket, state)
  end

  defp serve(socket, %{continuation: nil}, state) do
    receive do
      {:tcp, ^socket, data} -> handle_parse(socket, Redix.Protocol.parse(data), state)
      {:tcp_closed, ^socket} -> :ok
    end
  end

  defp serve(socket, %{continuation: fun}, state) do
    receive do
      {:tcp, ^socket, data} -> handle_parse(socket, fun.(data), state)
      {:tcp_closed, ^socket} -> :ok
    end
  end

  defp handle_parse(socket, {:continuation, fun}, state) do
    serve(socket, %{continuation: fun}, state)
  end

  defp handle_parse(socket, {:ok, req, left_over}, %{store: store} = state) do
    {resp, new_state} =
      case req do
        ["AUTH", _, _] ->
          handle_auth(req, state)

        _ ->
          try do
            case req do
              ["R", command | args] ->
                handle([command | Enum.map(args, fn r -> resolve(r, store) end)], state)

              _ ->
                handle(req, state)
            end
          rescue
            MaxTransferExceeded ->
              {encode_redis_error("Maximum transfer size exceeded"), state}

            DecoderError ->
              {encode_redis_error("Invalid BERT encoding"), state}

            MissingClusterError ->
              {encode_redis_error("Cluster not configured"), state}

            e in MissingVarError ->
              {encode_redis_error("Variable #{e.message} not found"), state}

            MulticodecError ->
              {encode_redis_error("Error resolving multicodec"), state}

            e in HTTPResolutionError ->
              {encode_redis_error("Variable #{e.message} did not resolve to a location"), state}

            e in DNSResolutionError ->
              {encode_redis_error("Variable #{e.message} did not resolve to a location"), state}

            e in MissingHashError ->
              {encode_redis_error("Storage is missing value for hash #{e.message}"), state}
          end
      end

    :gen_tcp.send(socket, resp)

    case left_over do
      "" -> serve(socket, %{continuation: nil}, new_state)
      _ -> handle_parse(socket, Redix.Protocol.parse(left_over), new_state)
    end
  end

  def do_remote(cluster, num, command, tree, args, state, use_local) do
    {:ok, pid} = PeerGroup.start_link(cluster, num, tree)

    case PeerGroup.has_peer(pid, 5_000) do
      true ->
        new_make_store = fn hash, ttl ->
          {:ok, store} =
            if use_local do
              state.make_store.(hash, ttl)
            else
              CrissCross.Store.CacheStore.create()
            end

          CachedRPC.create(pid, cluster, hash, store)
        end

        try do
          handle([command, tree | args], %{
            state
            | make_store: new_make_store
          })
        after
          PeerGroup.stop(pid)
        end

      false ->
        {encode_redis_error("No available peers"), state}
    end
  end

  def get_conns(_cluster, _num, _tree, _state, skip_nodes)
      when length(skip_nodes) > @max_peer_tries do
    {:error, "Tried #{@max_peer_tries} peers"}
  end

  def get_conns(cluster, num, tree, state, skip_nodes) do
    peers = CrissCross.find_peers_for_header(cluster, tree, num, skip_nodes)

    case peers do
      [_ | _] = peers ->
        ret =
          Stream.repeatedly(fn -> Enum.random(peers) end)
          |> Enum.take(num)
          |> Enum.reduce_while([], fn peer, conns ->
            case ConnectionCache.get_conn(cluster, peer.ip, peer.port) do
              {:ok, conn} ->
                {:cont, [conn | conns]}

              {:error, error} ->
                Logger.error("Could not connect to peer #{inspect(peer)} #{inspect(error)}")
                {:halt, {:error, peer}}
            end
          end)

        case ret do
          conns when is_list(conns) ->
            {:ok, conns}

          {:error, peer} ->
            get_conns(cluster, num, tree, state, [peer | skip_nodes])
        end

      [] ->
        {:error, "No available peers"}
    end
  end

  def codec_decode(<<0x00>> <> raw) do
    {:ok, {raw, :identity}}
  end

  def codec_decode("U" <> raw) do
    {:ok, {raw, :raw}}
  end

  def codec_decode(<<187, 3>> <> raw) do
    {:ok, {raw, :https}}
  end

  def codec_decode(<<224, 3>> <> raw) do
    {:ok, {raw, :http}}
  end

  def codec_decode("8" <> raw) do
    {:ok, {raw, :dnsaddr}}
  end

  def codec_decode(<<v::binary-size(1), _::binary>>) do
    {:error, "Unsupported codec #{inspect(v)}"}
  end

  def resolve(var, store) do
    case codec_decode(var) do
      {:ok, {val, type}} ->
        resolve(type, val, store)

      {:error, e} ->
        raise MulticodecError, inspect(e)
    end
  end

  def resolve(:identity, "defaultcluster", _store) do
    CrissCrossDHT.ClusterWatcher.default_cluster()
  end

  def resolve(:identity, local_var, store) do
    case KVStore.get(store, Enum.join(["vars", local_var], "-")) do
      val when is_binary(val) ->
        val

      _ ->
        raise MissingVarError, local_var
    end
  end

  def resolve(:raw, val, _store) do
    val
  end

  def resolve(:dnsaddr, dns_addr, _store) do
    case :inet_res.getbyname(to_charlist("_crisscross." <> dns_addr), :txt) do
      {:ok, {:hostent, _, _, :txt, _, [[v | _] | _]}} ->
        case IO.iodata_to_binary(v) do
          "data=" <> location ->
            DHTUtils.decode_human!(location)

          e ->
            Logger.error("DNS TXT Location did not match format data= #{dns_addr}: #{inspect(e)}")

            raise DNSResolutionError, dns_addr
        end

      {:ok, e} ->
        Logger.error("DNS resolution error for #{dns_addr}: #{inspect(e)}")
        raise DNSResolutionError, dns_addr

      {:error, e} ->
        Logger.error("DNS resolution error #{dns_addr}: #{inspect(e)}")
        raise DNSResolutionError, dns_addr
    end
  end

  def resolve(:http, addr, _store) do
    resolve_or_cache(addr)
  end

  def resolve(:https, addr, _store) do
    resolve_or_cache(addr)
  end

  def resolve(:multihash, val, _store) do
    val
  end

  def resolve_or_cache(full_addr) do
    case Cachex.get!(:cached_vars, full_addr) do
      nil ->
        l = resolve_link(full_addr)
        Cachex.put!(:cached_vars, full_addr, l)
        l

      v when is_binary(v) ->
        v
    end
  end

  def resolve_link(link) do
    case :httpc.request(link) do
      {:ok, {{_, 200, _}, _header, body}} ->
        case YamlElixir.read_from_string(IO.iodata_to_binary(body)) do
          {:ok, %{"data" => location}} ->
            DHTUtils.decode_human!(location)

          {:ok, e} ->
            Logger.error("Excepted \"data\" key in YAML for variable #{link} got: #{inspect(e)}")

            raise HTTPResolutionError, link

          {:error, e} ->
            Logger.error(
              "Unexpected error unpacking YAML for variable #{link} got: #{inspect(e)}"
            )

            raise HTTPResolutionError, link
        end

      e ->
        Logger.error("Unexpected error requesting YAML for variable #{link} got: #{inspect(e)}")
        raise HTTPResolutionError, link
    end
  end

  def do_remote_job(cluster, num, tree, args, state, timeout) do
    {:ok, peer_group} = PeerGroup.start_link(cluster, num, tree)
    max_attempts = 3

    try do
      case PeerGroup.has_peer(peer_group, timeout) do
        true ->
          results =
            Enum.map(args, fn {method, arg} ->
              Task.async(fn ->
                now = :os.system_time(:millisecond)

                Enum.reduce_while(
                  1..max_attempts,
                  {:error, %Redix.Error{message: "No connections"}},
                  fn attempt, last_err ->
                    time_left = timeout - (:os.system_time(:millisecond) - now)

                    conns =
                      if time_left > 0 do
                        PeerGroup.get_conns(peer_group, min(time_left, 5_000))
                      else
                        []
                      end

                    case conns do
                      [] ->
                        if attempt < max_attempts do
                          Process.sleep(500)
                        end

                        {:cont, last_err}

                      _ ->
                        conn = Enum.random(conns)

                        result =
                          ConnectionCache.command(
                            conn,
                            "DO",
                            cluster,
                            serialize_bert([tree, method, arg, time_left]),
                            time_left
                          )

                        case result do
                          {:error, e} ->
                            PeerGroup.bad_conn(peer_group, conn)
                            {:cont, {:error, e}}

                          {:ok, res_encrypted} ->
                            case decrypt_cluster_message(cluster, res_encrypted) do
                              decrypted when is_binary(decrypted) ->
                                {:halt, {:ok, decrypted}}

                              e ->
                                {:cont, e}
                            end
                        end
                    end
                  end
                )
              end)
            end)
            |> Task.await_many(timeout + 1000)

          redis_results =
            Enum.map(results, fn
              {:ok, [result, signature]} ->
                [encode_redis_list([result, signature])]

              {:error, e} when is_binary(e) ->
                [encode_redis_string(e)]

              {:error, e} ->
                [encode_redis_string(Exception.message(e))]
            end)

          {encode_redis_list_raw(redis_results), state}

        false ->
          {encode_redis_error("No available peers"), state}
      end
    after
      PeerGroup.stop(peer_group)
    end
  end

  def handle_auth(["AUTH", _, _], %{auth: "", authed: false} = state) do
    {encode_redis_error("AUTH not supported"), state}
  end

  def handle_auth(["AUTH", username, password], %{auth: auth, authed: false} = state) do
    if auth == Enum.join([username, password], ":") do
      {redis_ok(), %{state | authed: true}}
    else
      {encode_redis_error("Invalid credentials"), state}
    end
  end

  def subscribe_loop(tree, socket, stop_ref) do
    CrissCross.ProcessQueue.get_next(tree)

    receive do
      {:queue_response, {query, method, arg_bin, timeout, ref, pid} = resp} ->
        to_send =
          serialize_bert([
            method,
            arg_bin,
            ref
          ])

        Cachex.put!(:pids, ref, {pid, query}, ttl: timeout * 2)

        res = :gen_tcp.send(socket, encode_redis_list(["message", tree, to_send]))

        case res do
          :ok ->
            subscribe_loop(tree, socket, stop_ref)

          {:error, _e} ->
            CrissCross.ProcessQueue.add_to_queue(tree, resp)
            :ok
        end

      {:stop, ^stop_ref} ->
        :ok
    end
  end

  def subscribe_loop_send(socket, ref) do
    {socket, to_send} =
      receive do
        {^ref, :socket, socket} ->
          {socket, nil}

        {:new_stream_message, msg} ->
          {socket, deserialize_bert(msg)}

        :stream_finished ->
          {socket, :stop}

        {^ref, :stop} ->
          {socket, :stop}
      end

    if to_send != :stop do
      if to_send != nil and socket != nil do
        res =
          case to_send do
            {:ok, s} ->
              :gen_tcp.send(socket, encode_redis_list(["pmessage", ref, "", serialize_bert(s)]))

            {:error, e} ->
              :gen_tcp.send(socket, encode_redis_list(["pmessage", ref, "", serialize_bert([e])]))
          end

        case res do
          :ok -> subscribe_loop_send(socket, ref)
          _ -> :ok
        end
      else
        subscribe_loop_send(socket, ref)
      end
    end
  end

  def subscribe_loop_send_local(socket, ref) do
    {socket, to_send} =
      receive do
        {^ref, :socket, socket} ->
          {socket, nil}

        {^ref, resp, signature} ->
          {socket, serialize_bert([resp, signature])}

        {^ref, :stop} ->
          {socket, :stop}
      end

    if to_send != :stop do
      if to_send != nil and socket != nil do
        res =
          :gen_tcp.send(
            socket,
            encode_redis_list(["pmessage", ref, "", to_send])
          )

        case res do
          :ok -> subscribe_loop_send_local(socket, ref)
          _ -> :ok
        end
      else
        subscribe_loop_send_local(socket, ref)
      end
    end
  end

  def handle_subscription(
        ["PSUBSCRIBE", ref],
        %{subscriptions: subscriptions, socket: socket} = state
      ) do
    :gen_tcp.send(socket, encode_redis_list(["psubscribe", ref, 1]))

    case Cachex.get!(:waiting_streams, ref) do
      {pid, ref} ->
        send(pid, {ref, :socket, socket})
        {"", %{state | subscriptions: Map.put(subscriptions, ref, {pid, ref})}}

      nil ->
        {"", state}
    end
  end

  def handle_subscription(
        ["SUBSCRIBE", tree],
        %{subscriptions: subscriptions, socket: socket} = state
      ) do
    if Map.has_key?(subscriptions, tree) do
      :gen_tcp.send(socket, encode_redis_list(["subscribe", tree, 1]))
      {"", state}
    else
      stop_ref = make_ref()

      {:ok, pid} =
        Task.Supervisor.start_child(CrissCross.TaskSupervisor, fn ->
          subscribe_loop(tree, socket, stop_ref)
        end)

      :gen_tcp.send(socket, encode_redis_list(["subscribe", tree, 1]))

      {"", %{state | subscriptions: Map.put(subscriptions, tree, {pid, stop_ref})}}
    end
  end

  def handle_subscription(
        ["UNSUBSCRIBE", tree],
        %{subscriptions: subscriptions, socket: socket} = state
      ) do
    case Map.pop(subscriptions, tree) do
      {{pid, ref}, new_map} ->
        send(pid, {ref, :stop})
        :gen_tcp.send(socket, encode_redis_list(["unsubscribe", tree, 0]))
        {"", %{state | subscriptions: new_map}}

      {nil, new_map} ->
        :gen_tcp.send(socket, encode_redis_list(["unsubscribe", tree, 0]))
        {"", %{state | subscriptions: new_map}}
    end
  end

  def handle_subscription(
        ["PUNSUBSCRIBE", ref],
        %{subscriptions: subscriptions, socket: socket} = state
      ) do
    case Map.pop(subscriptions, ref) do
      {{pid, ref}, new_map} ->
        send(pid, {ref, :stop})
        :gen_tcp.send(socket, encode_redis_list(["punsubscribe", ref, 0]))
        {"", %{state | subscriptions: new_map}}

      {nil, new_map} ->
        :gen_tcp.send(socket, encode_redis_list(["punsubscribe", ref, 0]))
        {"", %{state | subscriptions: new_map}}
    end
  end

  def handle_subscription(["RESET"], %{subscriptions: subscriptions} = state) do
    Enum.each(subscriptions, fn {_, {pid, ref}} ->
      send(pid, {ref, :stop})
    end)

    {redis_ok(), %{state | subscriptions: %{}}}
  end

  def handle_iter(["ITERSTART", tree], %{make_store: make_store} = state) do
    {:ok, store} = make_store.(clean_maybe(tree), nil)
    btree = CubDB.Btree.new(store)
    {:ok, pid} = Scanner.start_link(btree, false, nil, nil)
    {redis_ok(), %{state | iterator: pid}}
  end

  def handle_iter(
        ["ITERSTART", tree, min_key, max_key, inc_min, inc_max, reverse],
        %{make_store: make_store} = state
      ) do
    mink =
      case clean_maybe(min_key) do
        nil -> nil
        k -> {deserialize_bert(k), clean_bool(inc_min)}
      end

    maxk =
      case clean_maybe(max_key) do
        nil -> nil
        k -> {deserialize_bert(k), clean_bool(inc_max)}
      end

    {:ok, store} = make_store.(clean_maybe(tree), nil)
    btree = CubDB.Btree.new(store)
    {:ok, pid} = Scanner.start_link(btree, clean_bool(reverse), mink, maxk)
    {redis_ok(), %{state | iterator: pid}}
  end

  def handle_iter(["ITERNEXT"], %{iterator: pid} = state) when is_pid(pid) do
    case Scanner.next(pid) do
      {k, v} ->
        {encode_redis_list([serialize_bert(k), serialize_bert(v)]), state}

      :done ->
        {"+DONE\r\n", %{state | iterator: nil}}
    end
  end

  def handle_iter(["ITERSTOP"], %{iterator: pid} = state) when is_pid(pid) do
    GenServer.stop(pid)
    {redis_ok(), %{state | iterator: nil}}
  end

  def handle_iter(_, state) do
    {encode_redis_error("Not in Iterator"), state}
  end

  def handle(_, %{auth: auth, authed: false} = state) when auth != "" do
    {encode_redis_error("Not Authenticated"), state}
  end

  def handle([command | rest], state)
      when command in ["SUBSCRIBE", "PUNSUBSCRIBE", "PSUBSCRIBE", "UNSUBSCRIBE", "RESET"] do
    handle_subscription([command | rest], state)
  end

  def handle([command | rest], state) when command in ["ITERSTART", "ITERNEXT", "ITERSTOP"] do
    handle_iter([command | rest], state)
  end

  def handle(_, %{subscriptions: subscriptions} = state) when map_size(subscriptions) > 0 do
    {encode_redis_error("In PubSub Mode"), state}
  end

  def handle(_, %{iterator: it} = state) when is_pid(it) do
    {encode_redis_error("Active Iterator"), state}
  end

  def handle(["REMOTENOLOCAL", cluster, num_remotes, command, tree | args], state)
      when command in @read_commands do
    case Integer.parse(num_remotes) do
      {num, _} when num > 0 ->
        do_remote(cluster, num, command, tree, args, state, false)

      _ ->
        {encode_redis_error("Invalid number of peers"), state}
    end
  end

  def handle(["REMOTE", cluster, num_remotes, command, tree | args], state)
      when command in @read_commands do
    case Integer.parse(num_remotes) do
      {num, _} when num > 0 ->
        do_remote(cluster, num, command, tree, args, state, true)

      _ ->
        {encode_redis_error("Invalid number of peers"), state}
    end
  end

  def handle(["VARWITH", local_var, command | args], %{store: store} = state) do
    case KVStore.get(store, Enum.join(["vars", local_var], "-")) do
      val when is_binary(val) ->
        if command in ["REMOTE", "REMOTENOLOCAL"] do
          case args do
            [cluster, remotes, subcommand | rest] ->
              {handle([command, cluster, remotes, subcommand, val | rest], state), state}

            _ ->
              encode_redis_error("#{command} use with VARWITH malformed")
          end
        else
          handle([command, val | args], state)
        end

      _ ->
        {encode_redis_error("Invalid VAR"), state}
    end
  end

  def handle(["VARSET", local_var, val], %{store: store} = state) do
    case KVStore.put(store, Enum.join(["vars", local_var], "-"), val) do
      :ok ->
        {redis_ok(), state}

      {:error, e} ->
        {encode_redis_error("error #{inspect(e)}"), state}
    end
  end

  def handle(
        ["REMOTE", cluster, num_remotes, "JOBDO", tree, timeout_str, method, argument | rest],
        state
      )
      when rem(length(rest), 2) == 0 do
    case Integer.parse(num_remotes) do
      {num, _} when num > 0 ->
        case Integer.parse(timeout_str) do
          {timeout, _} when timeout > 0 ->
            commands =
              [method, argument | rest]
              |> Enum.chunk_every(2)
              |> Enum.map(fn [k, v] ->
                {k, v}
              end)

            do_remote_job(cluster, num, tree, commands, state, timeout)

          _ ->
            {encode_redis_error("Invalid timeout"), state}
        end

      _ ->
        {encode_redis_error("Invalid number of peers"), state}
    end
  end

  def handle(
        ["JOBDO", tree, timeout_str, method, argument | rest],
        state
      )
      when rem(length(rest), 2) == 0 do
    case Integer.parse(timeout_str) do
      {timeout, _} when timeout > 0 ->
        t =
          Task.async(fn ->
            refs =
              [method, argument | rest]
              |> Enum.chunk_every(2)
              |> Enum.map(fn [k, v] ->
                ref = make_job_ref()

                :ok =
                  CrissCross.ProcessQueue.add_to_queue(
                    tree,
                    {tree <> k <> v, k, v, timeout, ref, self()}
                  )

                ref
              end)

            now = :os.system_time(:millisecond)

            Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
              time_left = timeout - (:os.system_time(:millisecond) - now)

              receive do
                {^ref, resp, signature} ->
                  {:cont, {:ok, [encode_redis_list([resp, signature]) | acc]}}

                {^ref, :queue_too_big} ->
                  {:halt, {:error, encode_redis_string("Queue too big")}}
              after
                time_left ->
                  {:halt, {:error, encode_redis_string("Timeout")}}
              end
            end)
          end)

        case Task.await(t, timeout + 100) do
          {:ok, to_send} -> {encode_redis_list_raw(to_send), state}
          {:error, to_send} -> {to_send, state}
        end

      _ ->
        {encode_redis_error("Invalid timeout"), state}
    end
  end

  def handle(
        ["REMOTE", cluster, "1", "STREAMSTART", tree],
        %{streams: streams} = state
      ) do
    ref = make_job_ref()
    {:ok, peer_group} = PeerGroup.start_link(cluster, 1, tree)

    try do
      if PeerGroup.has_peer(peer_group, 5000) do
        case PeerGroup.get_conns(peer_group, 5_000) do
          [] ->
            {encode_redis_error("No available connections"), state}

          [{:quic, endpoint, conn, _} | _] ->
            {:ok, pid} =
              Task.Supervisor.start_child(CrissCross.TaskSupervisor, fn ->
                subscribe_loop_send(nil, ref)
              end)

            case ExP2P.bidirectional_open(endpoint, conn, pid) do
              {:ok, stream} ->
                Cachex.put!(:waiting_streams, ref, {pid, ref})

                {encode_redis_string(ref),
                 %{
                   state
                   | streams:
                       Map.put(streams, ref, {:remote_stream, cluster, endpoint, stream, tree})
                 }}

              {:error, error} ->
                {encode_redis_error(error), state}
            end
        end
      else
        {encode_redis_error("No available peers"), state}
      end
    after
      PeerGroup.stop(peer_group)
    end
  end

  def handle(
        ["STREAMSTART", tree],
        %{streams: streams} = state
      ) do
    ref = make_job_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(CrissCross.TaskSupervisor, fn ->
        subscribe_loop_send_local(nil, ref)
      end)

    Cachex.put!(:waiting_streams, ref, {pid, ref})

    {encode_redis_string(ref), %{state | streams: Map.put(streams, ref, {tree, pid})}}
  end

  def handle(
        ["STREAMSTOP", ref],
        %{streams: streams} = state
      ) do
    new_streams =
      case Map.pop(streams, ref) do
        {nil, _} ->
          streams

        {tree, s} when is_binary(tree) ->
          s

        {{:remote_stream, _cluster, endpoint, sender, _}, s} ->
          ExP2P.stream_finish(endpoint, sender)
          s
      end

    {redis_ok(), %{state | streams: new_streams}}
  end

  def handle(
        ["STREAMSEND", ref, method, argument, timeout_str],
        %{streams: streams} = state
      ) do
    case Integer.parse(timeout_str) do
      {timeout, _} when timeout > 0 ->
        case Map.get(streams, ref) do
          nil ->
            {redis_ok(), state}

          {tree, pid} when is_binary(tree) ->
            :ok =
              CrissCross.ProcessQueue.add_to_queue(
                tree,
                {tree <> method <> argument, method, argument, timeout, ref, pid}
              )

            {redis_ok(), state}

          {:remote_stream, cluster, endpoint, sender, tree} ->
            payload = serialize_bert([tree, method, argument, timeout, ref])
            encrypted = encrypt_cluster_message(cluster, payload)
            command = ["STREAM", cluster, encrypted]

            case ExP2P.stream_send(endpoint, sender, serialize_bert(command), 10_000) do
              :ok -> {redis_ok(), state}
              {:error, error} -> {encode_redis_error(error), state}
            end
        end

      _ ->
        {encode_redis_error("Invalid timeout"), state}
    end
  end

  def handle(
        ["JOBGET", tree, timeout_str],
        %{socket: socket} = state
      ) do
    case Integer.parse(timeout_str) do
      {timeout, _} when timeout > 0 ->
        t =
          Task.async(fn ->
            CrissCross.ProcessQueue.get_next(tree)

            receive do
              {:queue_response, {query, method, arg_bin, timeout, ref, pid} = resp} ->
                to_send =
                  encode_redis_list_raw([
                    encode_redis_string(method),
                    encode_redis_string(arg_bin),
                    encode_redis_string(ref)
                  ])

                Cachex.put!(:pids, ref, {pid, query}, ttl: timeout * 2)

                res = :gen_tcp.send(socket, to_send)

                case res do
                  :ok ->
                    :ok

                  {:error, _e} ->
                    CrissCross.ProcessQueue.add_to_queue(tree, resp)
                    :ok
                end
            after
              timeout ->
                {:error, :timeout}
            end
          end)

        case Task.await(t, timeout + 100) do
          :ok ->
            {"", state}

          {:error, :timeout} ->
            {encode_redis_error("Timeout"), state}

          e ->
            Logger.error("Unexpected Error #{inspect(e)} queue")
            {encode_redis_error("Unexpected error"), state}
        end

      _ ->
        {encode_redis_error("Invalid timeout"), state}
    end
  end

  def handle(
        ["JOBRESPOND", reference, response, private_key_str],
        state
      ) do
    case DHTUtils.load_private_key(private_key_str) do
      {:ok, private_key} ->
        case Cachex.get!(:pids, reference) do
          nil ->
            Logger.warning("Responded to a unknown job.")
            :ok

          {pid, query_bin} ->
            {:ok, signature} = DHTUtils.sign(query_bin <> response, private_key)

            try do
              send(pid, {reference, response, signature})
            catch
              kind, reason ->
                formatted = Exception.format(kind, reason, __STACKTRACE__)
                Logger.error("Registry.dispatch/3 failed with #{formatted}")
            end
        end

        {redis_ok(), state}

      _ ->
        {encode_redis_error("Invalid private key"), state}
    end
  end

  def handle(
        ["JOBVERIFY", tree, method, argument, response, signature, public_key_str],
        state
      ) do
    case DHTUtils.load_public_key(public_key_str) do
      {:ok, key} ->
        value = tree <> method <> argument <> response

        if DHTUtils.verify_signature(key, value, signature) do
          {encode_redis_integer(1), state}
        else
          {encode_redis_integer(0), state}
        end

      _ ->
        {encode_redis_error("Invalid key"), state}
    end
  end

  def handle(c, state) do
    {handle_stateless(c, state), state}
  end

  def handle_stateless(["PING"], _state) do
    encode_redis_string("PONG")
  end

  def handle_stateless(["ECHO", val], _state) do
    encode_redis_string(val)
  end

  def handle_stateless(["JOBLOCAL", name, ttl], _state) do
    case Integer.parse(ttl) do
      {num, _} when num >= -1 ->
        Cachex.put!(:local_jobs, name, ttl: DHTUtils.adjust_ttl(num))
        redis_ok()

      _ ->
        encode_redis_error("Invalid TTL")
    end
  end

  def handle_stateless(["JOBANNOUNCE", cluster, tree, ttl], %{
        external_port: external_port
      }) do
    case Integer.parse(ttl) do
      {num, _} when num >= -1 ->
        CrissCrossDHT.search_announce(
          cluster,
          tree,
          fn _node ->
            :ok
          end,
          num,
          external_port,
          nil
        )

        redis_ok()

      _ ->
        encode_redis_error("Invalid TTL")
    end
  end

  def handle_stateless(["VARGET", local_var], %{store: store}) do
    case KVStore.get(store, Enum.join(["vars", local_var], "-")) do
      val when is_binary(val) ->
        encode_redis_string(val)

      _ ->
        encode_redis_error("Invalid VAR")
    end
  end

  def handle_stateless(["VARDELETE", local_var], %{store: store}) do
    case KVStore.delete(store, Enum.join(["vars", local_var], "-")) do
      {:ok, _val} ->
        redis_ok()

      _ ->
        encode_redis_error("Invalid VAR")
    end
  end

  def handle_stateless(["GETMULTIBIN", tree, loc | locs], %{make_store: make_store}) do
    loc_terms = [loc | locs]
    {:ok, store} = make_store.(clean_maybe(tree), nil)
    res = CrissCross.get_multi(store, loc_terms)
    Store.close(store)

    Enum.flat_map([loc | locs], fn l ->
      case Map.get(res, l) do
        nil -> []
        val -> [l, val]
      end
    end)
    |> encode_redis_list()
  end

  def handle_stateless(["BYTESWRITTEN", tree], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree), nil)
    {{loc, _}, _} = Store.get_latest_header(store)
    Store.close(store)
    encode_redis_integer(loc)
  end

  def handle_stateless(["COMPACT", tree, ttl], %{make_store: make_store}) do
    case Integer.parse(ttl) do
      {num, _} when num >= -1 ->
        {:ok, store} = make_store.(clean_maybe(tree), nil)
        {{old_size, _}, _} = Store.get_latest_header(store)
        {:ok, new_store} = make_store.(nil, num)

        btree = CubDB.Btree.new(store)
        compacted_btree = CubDB.Btree.load(btree, new_store)
        CubDB.Btree.sync(compacted_btree)

        {{new_size, new_loc}, _} = Store.get_latest_header(new_store)
        Store.close(store)
        Store.close(new_store)

        encode_redis_list_raw([
          encode_redis_string(new_loc),
          encode_redis_integer(new_size),
          encode_redis_integer(old_size)
        ])

      _ ->
        encode_redis_error("Invalid TTL")
    end
  end

  def handle_stateless(["GETMULTI", tree, loc | locs], %{make_store: make_store}) do
    loc_terms = [loc | locs] |> Enum.map(&deserialize_bert/1)
    {:ok, store} = make_store.(clean_maybe(tree), nil)
    res = CrissCross.get_multi(store, loc_terms)
    Store.close(store)

    Enum.flat_map(loc_terms, fn l ->
      case Map.get(res, l) do
        nil -> []
        val -> [l |> serialize_bert(), val |> serialize_bert()]
      end
    end)
    |> encode_redis_list()
  end

  def handle_stateless(["PERSIST", tree, ttl], %{make_store: make_store}) do
    case Integer.parse(ttl) do
      {num, _} when num >= -1 ->
        {:ok, store} = make_store.(clean_maybe(tree), DHTUtils.adjust_ttl(num))
        res = CrissCross.clone(store, make_store)
        Store.close(store)

        case res do
          :ok -> redis_ok()
          {:error, e} -> encode_redis_error("#{inspect(e)}")
        end

      _ ->
        encode_redis_error("Invalid TTL")
    end
  end

  def handle_stateless(["FETCH", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree), nil)

    r = CrissCross.fetch(store, loc |> deserialize_bert())
    Store.close(store)

    case r do
      {:ok, value} -> encode_redis_string(value |> serialize_bert())
      :error -> redis_nil()
    end
  end

  def handle_stateless(["FETCHBIN", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree), nil)
    r = CrissCross.fetch(store, loc)
    Store.close(store)

    case r do
      {:ok, value} -> encode_redis_string(value)
      :error -> redis_nil()
    end
  end

  def handle_stateless(["HASKEY", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree), nil)
    r = CrissCross.has_key?(store, loc |> deserialize_bert())
    Store.close(store)

    case r do
      true -> encode_redis_integer(1)
      false -> encode_redis_integer(0)
    end
  end

  def handle_stateless(["HASKEYBIN", tree, loc], %{make_store: make_store}) do
    {:ok, store} = make_store.(clean_maybe(tree), nil)
    r = CrissCross.has_key?(store, loc)
    Store.close(store)

    case r do
      true -> encode_redis_integer(1)
      false -> encode_redis_integer(0)
    end
  end

  def handle_stateless(["PUTMULTI", tree, ttl, key, value | kvs], %{make_store: make_store})
      when rem(length(kvs), 2) == 0 do
    case Integer.parse(ttl) do
      {num, _} when num >= -1 ->
        terms =
          [key, value | kvs]
          |> Enum.chunk_every(2)
          |> Enum.map(fn [k, v] ->
            {deserialize_bert(k), deserialize_bert(v)}
          end)

        {:ok, store} = make_store.(clean_maybe(tree), DHTUtils.adjust_ttl(num))
        location = CrissCross.put_multi(store, terms)
        Store.close(store)
        encode_redis_string(location)

      _ ->
        encode_redis_error("Invalid TTL")
    end
  end

  def handle_stateless(["PUTMULTIBIN", tree, ttl, key, value | kvs], %{make_store: make_store})
      when rem(length(kvs), 2) == 0 do
    case Integer.parse(ttl) do
      {num, _} when num >= -1 ->
        terms =
          [key, value | kvs]
          |> Enum.chunk_every(2)
          |> Enum.map(fn [k, v] ->
            {k, v}
          end)

        {:ok, store} = make_store.(clean_maybe(tree), DHTUtils.adjust_ttl(num))
        location = CrissCross.put_multi(store, terms)
        Store.close(store)
        encode_redis_string(location)

      _ ->
        encode_redis_error("Invalid TTL")
    end
  end

  def handle_stateless(["DELMULTI", tree, ttl, loc | locs], %{make_store: make_store}) do
    case Integer.parse(ttl) do
      {num, _} when num >= -1 ->
        {:ok, store} = make_store.(clean_maybe(tree), DHTUtils.adjust_ttl(num))
        location = CrissCross.delete_keys(store, Enum.map([loc | locs], &deserialize_bert/1))
        Store.close(store)
        encode_redis_string(location)

      _ ->
        encode_redis_error("Invalid TTL")
    end
  end

  def handle_stateless(["DELMULTIBIN", tree, ttl, loc | locs], %{make_store: make_store}) do
    case Integer.parse(ttl) do
      {num, _} when num >= -1 ->
        {:ok, store} = make_store.(clean_maybe(tree), DHTUtils.adjust_ttl(num))
        location = CrissCross.delete_keys(store, [loc | locs])
        Store.close(store)
        encode_redis_string(location)

      _ ->
        encode_redis_error("Invalid TTL")
    end
  end

  def handle_stateless(["SQL", tree, raw_ttl, statement | rest], %{make_store: make_store}) do
    case Integer.parse(raw_ttl) do
      {num, _} when num >= -1 ->
        ttl = DHTUtils.adjust_ttl(num)
        {:ok, store} = make_store.(clean_maybe(tree), ttl)
        {location, return} = CrissCross.sql(store, ttl, make_store, [statement | rest])
        Store.close(store)
        encode_redis_list([location] ++ Enum.map(return, &serialize_bert/1))

      _ ->
        encode_redis_error("Invalid TTL")
    end
  end

  def handle_stateless(["SQLREAD", tree, statement | rest], %{
        make_store: make_store
      }) do
    {:ok, store} = make_store.(clean_maybe(tree), nil)
    {_location, return} = CrissCross.sql(store, nil, make_store, [statement | rest])
    Store.close(store)
    encode_redis_list(Enum.map(return, &serialize_bert/1))
  end

  def handle_stateless(["ANNOUNCE", cluster, tree, ttl], %{
        external_port: external_port,
        make_store: make_store
      }) do
    ret =
      case Integer.parse(ttl) do
        {num, _} when num >= -1 ->
          {:ok, store} = make_store.(clean_maybe(tree), DHTUtils.adjust_ttl(num))
          :ok = CrissCross.announce(store, cluster, tree, external_port, num)
          Store.close(store)
          redis_ok()

        _ ->
          encode_redis_error("Invalid TTL")
      end

    ret
  end

  def handle_stateless(["HASANNOUNCED", cluster, tree], %{
        make_store: make_store
      }) do
    {:ok, store} = make_store.(clean_maybe(tree), nil)

    ret =
      case CrissCross.has_announced(store, cluster, tree) do
        true ->
          encode_redis_integer(1)

        _ ->
          encode_redis_integer(0)
      end

    Store.close(store)
    ret
  end

  def handle_stateless(["POINTERLOOKUP", cluster, name, generation], _state) do
    case Integer.parse(generation) do
      {num, _} when num >= 0 ->
        case CrissCross.find_pointer(cluster, name, num) do
          name when is_binary(name) -> encode_redis_string(name)
          :timeout -> redis_nil()
          :not_found -> redis_nil()
          {:error, e} -> encode_redis_error("Error setting pointer #{inspect(e)}")
        end

      _ ->
        encode_redis_error("Invalid Generation")
    end
  end

  def handle_stateless(["PUSH", cluster, tree, ttl], %{
        external_port: external_port,
        make_store: make_store
      }) do
    case Integer.parse(ttl) do
      {num, _} when num >= -1 ->
        {:ok, store} = make_store.(clean_maybe(tree), DHTUtils.adjust_ttl(num))
        :ok = CrissCross.announce(store, cluster, tree, external_port, num)
        CrissCrossDHT.store(cluster, tree, num)
        Store.close(store)
        redis_ok()

      _ ->
        encode_redis_error("Invalid TTL")
    end
  end

  def handle_stateless(["POINTERSET", cluster, private_key_pem, value, ttl], _state) do
    case DHTUtils.load_private_key(private_key_pem) do
      {:ok, private_key} ->
        case Integer.parse(ttl) do
          {num, _} when num >= -1 ->
            case CrissCross.set_pointer(cluster, private_key, value, num) do
              {l, _} when is_binary(l) -> encode_redis_string(l)
              {:error, e} -> encode_redis_error("#{inspect(e)}")
            end

          _ ->
            encode_redis_error("Invalid TTL")
        end

      _ ->
        encode_redis_error("Invalid private key")
    end
  end

  def handle_stateless(
        ["TUNNELOPEN", cluster, name, public_token, local_port_str, host, port_str],
        _state
      ) do
    case Integer.parse(port_str) do
      {port, _} when port >= 1 and port <= 65535 ->
        case Integer.parse(local_port_str) do
          {local_port, _} when local_port >= 1 and local_port <= 65535 ->
            ret =
              CrissCross.VPNClient.start_listening(
                cluster,
                name,
                public_token,
                local_port,
                host,
                port
              )

            case ret do
              {:ok, _pid} -> redis_ok()
              {:error, e} -> encode_redis_error("Tunnel error: #{e}")
            end

          _ ->
            encode_redis_error("Invalid port")
        end

      _ ->
        encode_redis_error("Invalid port")
    end
  end

  def handle_stateless(["TUNNELCLOSE", port_str], _state) do
    case Integer.parse(port_str) do
      {port, _} when port >= 1 and port <= 65535 ->
        CrissCross.VPNClient.shutdown_port(port)
        redis_ok()

      _ ->
        encode_redis_error("Invalid port")
    end
  end

  def handle_stateless(
        ["TUNNELALLOW", token, cluster, private_key_str, auth_token, host, port_str],
        %{tunnel_token: tunnel_token}
      ) do
    if tunnel_token != "" and tunnel_token != nil do
      if tunnel_token == token do
        case DHTUtils.load_private_key(private_key_str) do
          {:ok, key} ->
            name = DHTUtils.name_from_private_rsa_key(key)

            case Integer.parse(port_str) do
              {port, _} when port >= 1 and port <= 65535 ->
                ret = CrissCross.VPNConfig.allow_use(cluster, name, host, port, key, auth_token)

                case ret do
                  :ok -> redis_ok()
                  {:error, e} -> encode_redis_error("Tunnel error: #{e}")
                end

              _ ->
                encode_redis_error("Invalid port")
            end

          _ ->
            encode_redis_error("Invalid public key")
        end
      else
        encode_redis_error("Token does not match configured TUNNEL_TOKEN")
      end
    else
      encode_redis_error("Instance not configured to allow tunneling")
    end
  end

  def handle_stateless(["TUNNELDISALLOW", cluster, public_key_str, host, port_str], _state) do
    case DHTUtils.load_public_key(public_key_str) do
      {:ok, key} ->
        name = DHTUtils.name_from_public_key(key)

        case Integer.parse(port_str) do
          {port, _} when port >= 1 and port <= 65535 ->
            ret = CrissCross.VPNConfig.disallow_use(cluster, name, host, port)

            case ret do
              :ok -> redis_ok()
              {:error, e} -> encode_redis_error("Tunnel error: #{e}")
            end

          _ ->
            encode_redis_error("Invalid port")
        end

      _ ->
        encode_redis_error("Invalid public key")
    end
  end

  def handle_stateless(["KEYPAIR"], _state) do
    {:ok, pub, priv} = ExSchnorr.keypair()
    {:ok, pub_bytes} = ExSchnorr.public_to_bytes(pub)
    {:ok, priv_bytes} = ExSchnorr.private_to_bytes(priv)
    encode_redis_list([hash(hash(pub_bytes)), pub_bytes, priv_bytes])
  end

  def handle_stateless(["CLUSTER"], _state) do
    {:ok, pub, priv} = ExSchnorr.keypair()
    {:ok, pub_bytes} = ExSchnorr.public_to_bytes(pub)
    {:ok, priv_bytes} = ExSchnorr.private_to_bytes(priv)
    cypher = DHTUtils.gen_cypher()
    name = hash(DHTUtils.combine_to_sign([cypher, pub_bytes]))
    encode_redis_list([name, cypher, pub_bytes, priv_bytes])
  end

  def handle_stateless(c, _) do
    Logger.error("Invalid command #{inspect(c)}")
    encode_redis_error("Invalid command")
  end

  def clean_maybe("nil"), do: nil
  def clean_maybe(""), do: nil
  def clean_maybe(v), do: v

  def clean_bool("true"), do: true
  def clean_bool(_), do: false
end
