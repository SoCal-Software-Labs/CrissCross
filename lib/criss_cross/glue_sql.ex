defmodule CrissCross.GlueSql do
  defmodule Runner do
    alias CubDB.Btree

    def init([conn]) do
      {:ok, %{conn: conn, trees: %{}}}
    end

    def handle_info({:get, table, k, ref}, state) do
      table = :binary.list_to_bin(table)
      k = :binary.list_to_bin(k)

      case state.trees do
        %{^table => tree} ->
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

      case state.trees do
        %{^table => tree} ->
          new_tree =
            Enum.reduce(kvs, tree, fn {k, v}, tree_acc ->
              k = :binary.list_to_bin(k)
              v = :binary.list_to_bin(v)
              Btree.insert(tree_acc, k, v)
            end)
            |> Btree.commit()

          CrissCross.GlueSql.receive_result(ref, true, true, "", new_tree.root_loc)
          {:noreply, %{state | :trees => %{state.trees | table => new_tree}}}

        _ ->
          {:ok, store} = CrissCross.Store.Local.create(state.conn, nil)
          tree = CubDB.Btree.new(store)

          new_tree =
            Enum.reduce(kvs, tree, fn {k, v}, tree_acc ->
              k = :binary.list_to_bin(k)
              v = :binary.list_to_bin(v)
              Btree.insert(tree_acc, k, v)
            end)
            |> Btree.commit()

          CrissCross.GlueSql.receive_result(ref, true, true, "", new_tree.root_loc)
          {:noreply, %{state | :trees => Map.put(state.trees, table, new_tree)}}
      end
    end

    def handle_info({:delete, table, ks, ref}, state) do
      table = :binary.list_to_bin(table)

      case state.trees do
        %{^table => tree} ->
          new_tree =
            Enum.reduce(ks, tree, fn k, tree_acc ->
              k = :binary.list_to_bin(k)
              Btree.mark_deleted(tree_acc, k)
            end)
            |> Btree.commit()

          CrissCross.GlueSql.receive_result(ref, true, true, "", new_tree.root_loc)
          {:noreply, %{state | table => new_tree}}

        _ ->
          CrissCross.GlueSql.receive_result(ref, true, false, "", "not found")
          {:noreply, state}
      end
    end

    def handle_info({:start_scan, table, ref}, state) do
      table = :binary.list_to_bin(table)

      case state.trees do
        %{^table => tree} ->
          {:ok, pid} = CrissCross.Scanner.start_link(tree, false, nil, nil)

          CrissCross.GlueSql.receive_pid_result(ref, true, pid, "")
          {:noreply, state}

        _ ->
          CrissCross.GlueSql.receive_pid_result(ref, false, self, "not found")
          {:noreply, state}
      end
    end
  end

  use Rustler,
    otp_app: :criss_cross,
    crate: :crisscross_gluesql

  def start_sql(_arg1, _arg2), do: :erlang.nif_error(:nif_not_loaded)
  def stop(_arg1), do: :erlang.nif_error(:nif_not_loaded)
  def receive_result(_arg1, _arg2, _arg5, _arg3, _arg4), do: :erlang.nif_error(:nif_not_loaded)
  def receive_pid_result(_arg1, _arg2, _arg3, _arg4), do: :erlang.nif_error(:nif_not_loaded)
  def execute(_arg1, _arg2, _arg3, _arg4), do: :erlang.nif_error(:nif_not_loaded)

  def boot(timeout \\ 10_000) do
    ref = make_ref()
    {:ok, redis_conn} = Redix.start_link("redis://localhost:6379")
    {:ok, pid} = GenServer.start_link(Runner, [redis_conn])
    :ok = start_sql(pid, ref)

    receive do
      {:ok, sender, ^ref} -> {:ok, sender}
      {:error, error, ^ref} -> {:error, error}
    after
      timeout -> :timeout
    end
  end

  def test(timeout \\ 1_000) do
    {:ok, pid} = boot()

    statements =
      [
        "DROP TABLE IF EXISTS Glue;",
        "CREATE TABLE Glue (id INTEGER);",
        "INSERT INTO Glue VALUES (100);",
        "INSERT INTO Glue VALUES (200);",
        "SELECT * FROM Glue WHERE id > 100;"
      ]
      |> Enum.map(fn s ->
        ref = make_ref()
        execute(pid, self(), ref, s)

        receive do
          {:ok, result, ^ref} -> {:ok, result}
          {:error, error, ^ref} -> {:error, error}
        after
          timeout -> :timeout
        end
      end)
  end
end
