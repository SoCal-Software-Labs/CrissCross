defmodule CrissCross.Store.IPFS do
  @moduledoc false

  # `CubDB.Store.IPFS` is an implementation of the `Store` protocol
  # intended for test purposes only. It is backed by a map, but supports all the
  # operations of a `CubDB.Store`. It allows some tests to be simpler and faster
  # by avoid using the file system.

  defstruct put_client: nil,
            get_client: nil,
            prefix: nil,
            conn: nil,
            store_nodes_in_redis: false,
            agent_pid: nil

  alias CrissCross.Store.IPFS

  require Logger
  alias Tesla.Multipart

  def create(put_client, get_client, redis_opts, prefix, store_nodes_in_redis \\ false) do
    with {:ok, pid} <- Redix.start_link(redis_opts),
         {:ok, agent_pid} <- Agent.start_link(fn -> [] end) do
      {:ok,
       %IPFS{
         put_client: put_client,
         get_client: get_client,
         agent_pid: agent_pid,
         prefix: prefix,
         conn: pid,
         store_nodes_in_redis: store_nodes_in_redis
       }}
    end
  end

  def upload_file_to_ipfs(%IPFS{put_client: client}, filename, filebody) do
    mp =
      Multipart.new()
      |> Multipart.add_file_content(filebody, filename)

    case Tesla.post(
           client,
           "/api/v0/add?inline=true&pin=false&fscache=true&quieter=true&raw-leaves=true",
           mp
         ) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        String.split(body, "\n")
        |> Enum.filter(fn s -> s != "" end)
        |> Enum.map(fn json_blob ->
          %{"Hash" => qm_link} = Jason.decode!(json_blob)
          {:ok, qm_link}
        end)
        |> Enum.at(0)

      {:ok, %Tesla.Env{status: status, body: body}} ->
        Logger.error("ipfs-upload: #{body}")
        {:error, "Error connecting to IPFS cluster, HTTP Status: #{status}"}

      {:error, error} ->
        Logger.error("ipfs-upload: #{error}")
        {:error, "Error connecting to IPFS cluster"}
    end
  end

  def get_ipfs_hash(%IPFS{get_client: client}, filename, filebody) do
    mp =
      Multipart.new()
      |> Multipart.add_file_content(filebody, filename)

    case Tesla.post(
           client,
           "/api/v0/add?inline=true&pin=false&fscache=true&quieter=true&only-hash=true",
           mp
         ) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        String.split(body, "\n")
        |> Enum.filter(fn s -> s != "" end)
        |> Enum.map(fn json_blob ->
          %{"Hash" => qm_link} = Jason.decode!(json_blob)
          {:ok, qm_link}
        end)
        |> Enum.at(0)

      {:ok, %Tesla.Env{status: status, body: body}} ->
        Logger.error("ipfs-upload: #{body}")
        {:error, "Error connecting to IPFS cluster, HTTP Status: #{status}"}

      {:error, error} ->
        Logger.error("ipfs-upload: #{error}")
        {:error, "Error connecting to IPFS cluster"}
    end
  end

  def get_file_from_ipfs(%IPFS{get_client: client}, cid) do
    case Tesla.get(client, "/api/v0/cat?arg=" <> URI.encode(cid)) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        Logger.error("ipfs-get: #{body}")
        {:error, "Error connecting to IPFS cluster, HTTP Status: #{status}"}

      {:error, error} ->
        Logger.error("ipfs-get: #{error}")
        {:error, "Error connecting to IPFS cluster"}
    end
  end

  def ipfs_client_auth(endpoint, username, password) do
    middleware = [
      {Tesla.Middleware.BaseUrl, endpoint},
      {Tesla.Middleware.BasicAuth, %{username: username, password: password}}
    ]

    Tesla.client(middleware, {Tesla.Adapter.Finch, name: MyFinch})
  end

  def ipfs_client(endpoint) do
    middleware = [
      {Tesla.Middleware.BaseUrl, endpoint}
    ]

    Tesla.client(middleware, {Tesla.Adapter.Finch, name: MyFinch})
  end

  def ipfs_client_put(endpoint) do
    middleware = [
      {Tesla.Middleware.BaseUrl, endpoint}
    ]

    Tesla.client(middleware, {Tesla.Adapter.Finch, name: MyFinchPut})
  end
end

defimpl CubDB.Store, for: CrissCross.Store.IPFS do
  alias CrissCross.Store.IPFS

  def identifier(%IPFS{prefix: prefix}) do
    prefix
  end

  def clean_up(_store, cpid, btree) do
    :ok
  end

  def clean_up_old_compaction_files(store, pid) do
    :ok
  end

  def start_cleanup(%IPFS{}) do
    {:ok, nil}
  end

  def next_compaction_store(%IPFS{}) do
    Store.IPFS.create()
  end

  def put_node(
        %IPFS{
          conn: conn,
          agent_pid: agent,
          prefix: prefix,
          store_nodes_in_redis: store_nodes_in_redis
        } = ipfs,
        n
      ) do
    bin = serialize(n)

    case IPFS.get_ipfs_hash(ipfs, "", bin) do
      {:ok, loc} ->
        if store_nodes_in_redis do
          {:ok, "OK"} = Redix.command(conn, ["HMSET", prefix, loc, bin])
        end

        task = make_ref()

        Task.start(fn ->
          Process.sleep(1)

          case IPFS.upload_file_to_ipfs(ipfs, "", bin) do
            {:ok, loc} ->
              loc

            {:error, err} ->
              throw(err)
          end

          remove_task(ipfs, task)
        end)

        Agent.get_and_update(
          agent,
          fn tasks ->
            {loc, [task | tasks]}
          end,
          :infinity
        )

      e ->
        e
    end
  end

  def put_header(
        %IPFS{
          conn: conn,
          agent_pid: agent,
          prefix: prefix,
          store_nodes_in_redis: store_nodes_in_redis
        } = ipfs,
        header
      ) do
    bin = serialize(header)

    case IPFS.get_ipfs_hash(ipfs, "", bin) do
      {:ok, loc} ->
        if store_nodes_in_redis do
          {:ok, "OK"} = Redix.command(conn, ["HMSET", prefix, loc, bin])
        end

        task = make_ref()

        Task.start(fn ->
          Process.sleep(1)

          case IPFS.upload_file_to_ipfs(ipfs, "", bin) do
            {:ok, loc} ->
              {:ok, "OK"} = Redix.command(conn, ["HMSET", prefix, "root", loc])
              loc

            {:error, err} ->
              raise err
          end

          remove_task(ipfs, task)
        end)

        Agent.get_and_update(
          agent,
          fn tasks ->
            {loc, [task | tasks]}
          end,
          :infinity
        )

      e ->
        e
    end
  end

  def remove_task(%IPFS{agent_pid: agent_pid}, task) do
    Agent.get_and_update(
      agent_pid,
      fn tasks ->
        {:ok, List.delete(tasks, task)}
      end,
      :infinity
    )
  end

  def sync(ipfs) do
    # do_sync(ipfs)
    :ok
  end

  def do_sync(%IPFS{agent_pid: agent_pid} = ipfs) do
    tasks =
      Agent.get(
        agent_pid,
        fn tasks ->
          tasks
        end,
        :infinity
      )

    case tasks do
      [] ->
        :ok

      _ ->
        Process.sleep(10)
        do_sync(ipfs)
    end
  end

  def get_node(%IPFS{conn: conn, prefix: prefix, store_nodes_in_redis: true}, location) do
    case Redix.command(conn, ["HGET", prefix, location]) do
      {:ok, value} -> deserialize(value)
      _ = e -> e
    end
  end

  def get_node(%IPFS{conn: conn, prefix: prefix, store_nodes_in_redis: false} = ipfs, location) do
    case IPFS.get_file_from_ipfs(ipfs, location) do
      {:ok, value} -> deserialize(value)
      _ = e -> e
    end
  end

  def get_latest_header(%IPFS{conn: conn, prefix: prefix, store_nodes_in_redis: true}) do
    case Redix.command(conn, ["HGET", prefix, "root"]) do
      {:ok, nil} ->
        nil

      {:ok, header_loc} ->
        case Redix.command(conn, ["HGET", prefix, header_loc]) do
          {:ok, value} -> {header_loc, deserialize(value)}
          _ = e -> e
        end

      _ = e ->
        e
    end
  end

  def get_latest_header(%IPFS{conn: conn, prefix: prefix, store_nodes_in_redis: false} = ipfs) do
    case Redix.command(conn, ["HGET", prefix, "root"]) do
      {:ok, nil} ->
        nil

      {:ok, header_loc} ->
        case IPFS.get_file_from_ipfs(ipfs, header_loc) do
          {:ok, value} -> {header_loc, deserialize(value)}
          _ = e -> e
        end

      _ = e ->
        e
    end
  end

  def close(%IPFS{conn: conn}) do
    Agent.stop(conn, :normal, :infinity)
  end

  def blank?(%IPFS{conn: conn, prefix: prefix}) do
    case Redix.command(conn, ["HGET", prefix, "root"]) do
      {:ok, header_loc} when is_binary(header_loc) -> false
      _ = e -> true
    end
  end

  def open?(%IPFS{conn: conn}) do
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
