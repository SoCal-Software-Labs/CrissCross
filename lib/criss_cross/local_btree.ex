defmodule CrissCross.LocalBtree do
  def start_link(btree) do
    GenServer.start_link(__MODULE__, [btree])
  end

  def init([btree]) do
    {:ok,
     %{
       btree: btree
     }}
  end

  def handle_info({:put, k, v}, %{completed: true} = state) do
    {:noreply, :done, state}
  end

  def handle_info({:get, k, v}, %{completed: true} = state) do
    {:noreply, :done, state}
  end
end
