defmodule CrissCross.GlueSql do
  defmodule Runner do
    alias CubDB.Btree

    def init([tree, ttl, make_store]) do
      {:ok, %{make_store: make_store, ttl: ttl, trees: tree}}
    end

    def handle_call(:location, _, state) do
      {{_, location}, _} = CubDB.Store.get_latest_header(state.trees.store)
      {:reply, location, state}
    end

    def handle_info({:get, table, k, ref}, state) do
      table = :binary.list_to_bin(table)
      k = :binary.list_to_bin(k)

      case Btree.fetch(state.trees, table) do
        {:ok, {:embedded_tree, tree_hash, _}} ->
          {:ok, store} = state.make_store.(tree_hash, nil)
          tree = CubDB.Btree.new(store)

          case Btree.fetch(tree, k) do
            {:ok, value} -> CrissCross.GlueSql.receive_result(ref, true, true, k, value)
            _ -> CrissCross.GlueSql.receive_result(ref, false, false, k, "not found")
          end

        _ ->
          CrissCross.GlueSql.receive_result(ref, true, false, k, "tree not found")
      end

      {:noreply, state}
    end

    def handle_info({:put, table, kvs, ref}, state) do
      table = :binary.list_to_bin(table)

      case Btree.fetch(state.trees, table) do
        {:ok, {:embedded_tree, tree_hash, _}} ->
          {:ok, store} = state.make_store.(tree_hash, state.ttl)
          tree = CubDB.Btree.new(store)

          _new_tree =
            Enum.reduce(kvs, tree, fn {k, v}, tree_acc ->
              k = :binary.list_to_bin(k)
              v = :binary.list_to_bin(v)
              Btree.insert(tree_acc, k, v)
            end)
            |> Btree.commit()

          {{_, location}, _} = CubDB.Store.get_latest_header(store)
          CrissCross.GlueSql.receive_result(ref, true, true, "", location)

          {:noreply,
           %{
             state
             | :trees =>
                 Btree.insert(state.trees, table, {:embedded_tree, location, nil})
                 |> Btree.commit()
           }}

        _ ->
          {:ok, store} = state.make_store.(nil, state.ttl)
          tree = CubDB.Btree.new(store)

          _new_tree =
            Enum.reduce(kvs, tree, fn {k, v}, tree_acc ->
              k = :binary.list_to_bin(k)
              v = :binary.list_to_bin(v)
              Btree.insert(tree_acc, k, v)
            end)
            |> Btree.commit()

          {{_, location}, _} = CubDB.Store.get_latest_header(store)
          CrissCross.GlueSql.receive_result(ref, true, true, "", location)

          {:noreply,
           %{
             state
             | :trees =>
                 Btree.insert(state.trees, table, {:embedded_tree, location, nil})
                 |> Btree.commit()
           }}
      end
    end

    def handle_info({:delete, table, ks, ref}, state) do
      table = :binary.list_to_bin(table)

      case Btree.fetch(state.trees, table) do
        {:ok, {:embedded_tree, tree_hash, _}} ->
          {:ok, store} = state.make_store.(tree_hash, nil)
          tree = CubDB.Btree.new(store)

          _new_tree =
            Enum.reduce(ks, tree, fn k, tree_acc ->
              k = :binary.list_to_bin(k)
              Btree.mark_deleted(tree_acc, k)
            end)
            |> Btree.commit()

          {{_, location}, _} = CubDB.Store.get_latest_header(store)
          CrissCross.GlueSql.receive_result(ref, true, true, "", location)

          {:noreply,
           %{
             state
             | :trees =>
                 Btree.insert(state.trees, table, {:embedded_tree, location, nil})
                 |> Btree.commit()
           }}

        _ ->
          CrissCross.GlueSql.receive_result(ref, true, false, "", "not found")
          {:noreply, state}
      end
    end

    def handle_info({:start_scan, table, ref}, state) do
      table = :binary.list_to_bin(table)

      case Btree.fetch(state.trees, table) do
        {:ok, {:embedded_tree, tree_hash, _}} ->
          {:ok, store} = state.make_store.(tree_hash, nil)
          tree = CubDB.Btree.new(store)

          {:ok, pid} = CrissCross.Scanner.start_link(tree, false, nil, nil)

          CrissCross.GlueSql.receive_pid_result(ref, true, pid, "")
          {:noreply, state}

        _ ->
          CrissCross.GlueSql.receive_pid_result(ref, false, self(), "not found")
          {:noreply, state}
      end
    end
  end

  use Rustler,
    otp_app: :crisscross,
    crate: :crisscross_gluesql

  def start_sql(_arg1, _arg2), do: :erlang.nif_error(:nif_not_loaded)
  def stop(_arg1), do: :erlang.nif_error(:nif_not_loaded)
  def receive_result(_arg1, _arg2, _arg5, _arg3, _arg4), do: :erlang.nif_error(:nif_not_loaded)
  def receive_pid_result(_arg1, _arg2, _arg3, _arg4), do: :erlang.nif_error(:nif_not_loaded)
  def execute_statement(_arg1, _arg2, _arg3, _arg4), do: :erlang.nif_error(:nif_not_loaded)

  def boot(store, ttl, make_store, timeout \\ 1_000) do
    ref = make_ref()
    tree = CubDB.Btree.new(store)
    {:ok, pid} = GenServer.start_link(Runner, [tree, ttl, make_store])
    :ok = start_sql(pid, ref)

    receive do
      {:ok, sender, ^ref} -> {:ok, pid, sender}
      {:error, error, ^ref} -> {:error, error}
    after
      timeout -> :timeout
    end
  end

  def execute(pid, s, timeout \\ 1_000) do
    ref = make_ref()
    execute_statement(pid, self(), ref, s)

    receive do
      {:ok, result, ^ref} -> {:ok, result}
      {:error, error, ^ref} -> {:error, error}
    after
      timeout -> :timeout
    end
  end

  def run(store, ttl, make_store, statements, timeout \\ 5_000) do
    {:ok, pid, server} = boot(store, ttl, make_store, timeout)

    return =
      statements
      |> Enum.map(fn s ->
        execute(server, s, timeout)
      end)

    :ok = stop(server)
    location = GenServer.call(pid, :location)
    :ok = GenServer.stop(pid)
    {location, return}
  end
end
