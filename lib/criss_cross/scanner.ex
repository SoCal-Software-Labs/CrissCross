defmodule CrissCross.Scanner do
  @value CubDB.Btree.__value__()
  @deleted CubDB.Btree.__deleted__()
  @leaf CubDB.Btree.__leaf__()
  @branch CubDB.Btree.__branch__()

  alias CubDB.Store

  def start_link(btree, reverse, min_key, max_key) do
    GenServer.start_link(__MODULE__, [btree, reverse, min_key, max_key])
  end

  def next(pid) do
    GenServer.call(pid, :next)
  end

  def init([btree, reverse, min_key, max_key]) do
    root = fn -> {nil, btree.root} end

    {:ok,
     %{
       store: btree.store,
       node: {[], [[root]]},
       completed: false,
       reverse: reverse,
       min_key: min_key,
       max_key: max_key
     }}
  end

  def handle_call(:next, _, %{completed: true} = state) do
    {:stop, :normal, :done, state}
  end

  def handle_call(
        :next,
        _,
        %{store: store, node: n, min_key: min_key, max_key: max_key, reverse: reverse} = state
      ) do
    case CrissCross.next_node(n, store, &get_children(min_key, max_key, reverse, &1, &2)) do
      :done ->
        {:stop, :normal, :done, %{state | node: nil, completed: true}}

      {t, {k, value} = item} ->
        {:reply, item, %{state | node: t}}
    end
  end

  def handle_info(
        {:scan_next, ref},
        %{completed: true} = state
      ) do
    CrissCross.GlueSql.receive_result(ref, true, false, "", "")
    {:stop, :normal, state}
  end

  def handle_info(
        {:scan_next, ref},
        %{store: store, node: n, min_key: min_key, max_key: max_key, reverse: reverse} = state
      ) do
    case CrissCross.next_node(n, store, &get_children(min_key, max_key, reverse, &1, &2)) do
      :done ->
        CrissCross.GlueSql.receive_result(ref, true, false, "", "")
        {:stop, :normal, %{state | node: nil, completed: true}}

      {t, {k, value} = item} ->
        CrissCross.GlueSql.receive_result(ref, true, true, k, value)
        {:noreply, %{state | node: t}}
    end
  end

  defp get_children(min_key, max_key, reverse, {@branch, locs}, store) do
    children =
      locs
      |> Enum.chunk_every(2, 1)
      |> Enum.filter(fn
        [{key, _}, {next_key, _}] -> filter_branch(min_key, max_key, key, next_key)
        [{key, _}] -> filter_branch(nil, max_key, key, nil)
      end)
      |> Enum.map(fn [{k, loc} | _] ->
        fn -> {k, Store.get_node(store, loc)} end
      end)

    if reverse, do: Enum.reverse(children), else: children
  end

  defp get_children(min_key, max_key, reverse, {@leaf, locs}, store) do
    children =
      locs
      |> Enum.filter(fn {key, _} ->
        filter_leave(min_key, max_key, key)
      end)
      |> Enum.map(fn {k, loc} ->
        fn -> {k, Store.get_node(store, loc)} end
      end)

    if reverse, do: Enum.reverse(children), else: children
  end

  defp get_children(_, _, _, {@value, v}, _), do: v

  defp filter_branch(nil, nil, _, _), do: true
  defp filter_branch(nil, {max, true}, key, _), do: key <= max
  defp filter_branch(nil, {max, false}, key, _), do: key < max
  defp filter_branch({min, _}, nil, _, next_key), do: next_key > min
  defp filter_branch({min, _}, {max, true}, key, next_key), do: key <= max && next_key > min
  defp filter_branch({min, _}, {max, false}, key, next_key), do: key < max && next_key > min

  defp filter_leave(nil, nil, _), do: true
  defp filter_leave({min, true}, nil, key), do: key >= min
  defp filter_leave({min, false}, nil, key), do: key > min
  defp filter_leave(nil, {max, true}, key), do: key <= max
  defp filter_leave(nil, {max, false}, key), do: key < max
  defp filter_leave({min, true}, {max, true}, key), do: key >= min && key <= max
  defp filter_leave({min, false}, {max, true}, key), do: key > min && key <= max
  defp filter_leave({min, true}, {max, false}, key), do: key >= min && key < max
  defp filter_leave({min, false}, {max, false}, key), do: key > min && key < max
end
