defmodule CrissCross do
  require Logger

  @value CubDB.Btree.__value__()
  @deleted CubDB.Btree.__deleted__()
  @leaf CubDB.Btree.__leaf__()
  @branch CubDB.Btree.__branch__()

  defdelegate encode_human(item), to: CrissCrossDHT.Server.Utils, as: :encode_human
  defdelegate decode_human!(item), to: CrissCrossDHT.Server.Utils, as: :decode_human!

  def stream_db(store) do
    get_children = fn
      {@value, value}, _store ->
        value

      {_, locs}, store ->
        locs
        |> Enum.map(fn {k, loc} ->
          fn -> {k, CubDB.Store.get_node(store, loc)} end
        end)
    end

    btree = CubDB.Btree.new(store)
    root = fn -> {nil, btree.root} end

    Stream.unfold({[], [[root]]}, fn acc ->
      case next(acc, store, get_children) do
        :done -> nil
        {t, item} -> {item, t}
      end
    end)
  end

  def stream_concurrent(store, opts \\ []) do
    get_children = fn
      {_, locs}, store ->
        locs
        |> Enum.map(fn {k, loc} ->
          fn -> {k, CubDB.Store.get_node(store, loc)} end
        end)
    end

    btree = CubDB.Btree.new(store)
    root = fn -> {nil, btree.root} end

    Stream.unfold({[], [[root]]}, fn acc ->
      case next_task(acc, store, get_children) do
        :done -> nil
        {t, item} -> {item, t}
      end
    end)
    |> Task.async_stream(
      fn f ->
        f.()
      end,
      opts + [timeout: :infinity]
    )
    |> Stream.flat_map(fn
      {:ok, {k, {@value, value}}} -> [{k, value}]
      _ -> []
    end)
  end

  def next_node(n, s, gc), do: next(n, s, gc)

  defp next({[], [[] | todo]}, store, get_children) do
    case todo do
      [] -> :done
      _ -> next({[], todo}, store, get_children)
    end
  end

  defp next({[], [[n | rest] | todo]}, store, get_children) do
    case n.() do
      {_, leaf = {@leaf, _}} ->
        children = get_children.(leaf, store)
        next({children, [rest | todo]}, store, get_children)

      {_, branch = {@branch, _}} ->
        children = get_children.(branch, store)
        next({[], [children | [rest | todo]]}, store, get_children)
    end
  end

  defp next({[n | rest], todo}, store, get_children) do
    case n.() do
      {k, value = {@value, _}} -> {{rest, todo}, {k, get_children.(value, store)}}
      {_k, @deleted} -> next({rest, todo}, store, get_children)
    end
  end

  defp next_task({[], [[] | todo]}, store, get_children) do
    case todo do
      [] -> :done
      _ -> next_task({[], todo}, store, get_children)
    end
  end

  defp next_task({[], [[n | rest] | todo]}, store, get_children) do
    case n.() do
      {_, leaf = {@leaf, _}} ->
        children = get_children.(leaf, store)
        next_task({children, [rest | todo]}, store, get_children)

      {_, branch = {@branch, _}} ->
        children = get_children.(branch, store)
        next_task({[], [children | [rest | todo]]}, store, get_children)
    end
  end

  defp next_task({[n | rest], todo}, _store, _get_children) do
    {{rest, todo}, n}
  end

  def sql(local_store, ttl, make_store, statements) do
    CrissCross.GlueSql.run(local_store, ttl, make_store, statements)
  end

  def get_multi(local_store, ks) do
    {:ok, db} = CubDB.start_link(local_store, auto_file_sync: false, auto_compact: false)
    CubDB.get_multi(db, ks)
  end

  def put_multi(local_store, kvs) do
    {:ok, db} = CubDB.start_link(local_store, auto_file_sync: false, auto_compact: false)
    :ok = CubDB.put_multi(db, kvs)
    {{_, location}, _} = CubDB.Store.get_latest_header(local_store)
    location
  end

  def delete_keys(local_store, locs) do
    {:ok, db} = CubDB.start_link(local_store, auto_file_sync: false, auto_compact: false)
    :ok = CubDB.delete_multi(db, locs)
    {{_, location}, _} = CubDB.Store.get_latest_header(local_store)
    location
  end

  def fetch(local_store, loc) do
    {:ok, db} = CubDB.start_link(local_store, auto_file_sync: false, auto_compact: false)
    CubDB.fetch(db, loc)
  end

  def has_key?(local_store, loc) do
    {:ok, db} = CubDB.start_link(local_store, auto_file_sync: false, auto_compact: false)
    CubDB.has_key?(db, loc)
  end

  def find_pointer(cluster, public_key, generation \\ 0) do
    case CrissCrossDHT.find_name_sync(cluster, public_key, generation) do
      {_remote, name} -> name
      e -> e
    end
  end

  def set_pointer(cluster, private_key, value, ttl) do
    CrissCrossDHT.store_name(cluster, private_key, value, true, true, ttl)
  end

  def clone(store, make_store) do
    stream_concurrent(store)
    |> Stream.flat_map(fn s ->
      case s do
        {_, {:embedded_tree, t, _}} -> [t]
        _ -> []
      end
    end)
    |> Stream.map(fn t ->
      Logger.debug("Cloning embedded #{inspect(t)}")
      {:ok, store} = make_store.(t)

      stream_concurrent(store)
      |> Stream.run()

      CubDB.Store.close(store)
    end)
    |> Stream.run()
  end

  def tree_size(store) do
    btree = CubDB.Btree.new(store)
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    get_children = fn
      {@value, value} = node, _store ->
        Agent.update(agent, fn acc -> acc + :erlang.external_size(node) end)
        value

      {_, locs} = node, store ->
        Agent.update(agent, fn acc -> acc + :erlang.external_size(node) end)

        locs
        |> Enum.map(fn {k, loc} ->
          {k, CubDB.Store.get_node(store, loc)}
        end)
        |> Enum.filter(fn {_, node} ->
          node != @deleted
        end)
    end

    fun = fn _, _ -> {:cont, :ok} end

    {:done, :ok} = CubDB.Btree.Enumerable.reduce(btree, {:cont, :ok}, fun, get_children)

    ret = Agent.get(agent, fn list -> list end)
    Agent.stop(agent)
    ret
  end

  def has_announced(_store, cluster, tree_hash) do
    CrissCrossDHT.has_announced(
      cluster,
      tree_hash
    )
  end

  def announce(store, cluster, tree_hash, local_port, ttl) do
    {:ok, store} = CrissCross.Store.AnnouncingStore.create(cluster, ttl, store)

    stream_db(store)
    |> Stream.run()

    CrissCrossDHT.search_announce(
      cluster,
      tree_hash,
      fn _node ->
        :ok
      end,
      ttl,
      local_port
    )
  end

  def announce_have_tree(cluster, tree_hash, local_port, ttl) do
    CrissCrossDHT.search_announce(
      cluster,
      tree_hash,
      fn _node ->
        :ok
      end,
      ttl,
      local_port
    )
  end

  def find_peers_for_header(cluster, tree_hash, n \\ 1, skip_nodes \\ [], timeout \\ 5_000) do
    maxtime = :os.system_time(:millisecond) + timeout - 100

    task =
      Task.async(fn ->
        task_pid = self()
        task_ref = make_ref()

        CrissCrossDHT.search(cluster, tree_hash, fn
          :done ->
            send(task_pid, {task_ref, :done})

          {ip, port, meta} ->
            n = %{ip: ip, port: port, meta: meta}

            if not Enum.member?(skip_nodes, n) and
                 Cachex.get(:blacklisted_ips, {ip, port}) == {:ok, nil} do
              send(task_pid, {task_ref, n})
            end
        end)

        this_timeout = maxtime - :os.system_time(:millisecond)

        Enum.reduce_while(1..n, [], fn _, acc ->
          receive do
            {^task_ref, :done} -> {:halt, acc}
            {^task_ref, node} -> {:cont, [node | acc]}
          after
            this_timeout ->
              {:halt, acc}
          end
        end)
      end)

    Task.await(task, timeout)
  end

  def clean_tree(tree) do
    tree
  end
end
