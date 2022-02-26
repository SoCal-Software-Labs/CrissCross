defmodule CrissCross.ProcessQueue do
  use GenServer

  require Logger

  @max_queue_size 1000
  @clean_timer 10_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(path) do
    Process.send_after(self(), :clean, @clean_timer)
    {:ok, %{waiting: %{}, queues: %{}}}
  end

  def get_next(location),
    do: GenServer.cast(__MODULE__, {:get_next, location, self()})

  def add_to_queue(location, payload),
    do: GenServer.cast(__MODULE__, {:add_to_queue, location, payload})

  def add_to_q(queue_dict, location, obj) do
    case queue_dict do
      %{^location => q} ->
        if is_pid(obj) do
          Map.put(queue_dict, location, :queue.in(obj, clean_waiting(q)))
        else
          Map.put(queue_dict, location, :queue.in(obj, q))
        end

      _ ->
        Map.put(queue_dict, location, :queue.from_list([obj]))
    end
  end

  def clean_waiting(q) do
    case :queue.out(q) do
      {{:value, v}, nq} ->
        if Process.alive?(v) do
          q
        else
          clean_waiting(nq)
        end

      {:empty, _} ->
        q
    end
  end

  def clean_queues(q) do
    case :queue.out(q) do
      {{:value, {_query, _method, _argument, _timeout, _ref, waiting_pid}}, nq} ->
        if Process.alive?(waiting_pid) do
          q
        else
          clean_queues(nq)
        end

      {:empty, _} ->
        q
    end
  end

  def handle_info(:clean, %{queues: queues, waiting: waiting} = state) do
    new_queues = Enum.map(queues, fn {k, q} -> {k, clean_queues(q)} end) |> Enum.into(%{})
    new_waiting = Enum.map(waiting, fn {k, q} -> {k, clean_waiting(q)} end) |> Enum.into(%{})
    Process.send_after(self(), :clean, @clean_timer)
    {:noreply, %{state | waiting: new_waiting, queues: new_queues}}
  end

  def handle_cast(
        {:get_next, location, pid},
        %{queues: queues, waiting: waiting} = state
      ) do
    queue = Map.get(queues, location, :queue.new())

    case :queue.out(queue) do
      {{:value, {_query, _method, _argument, _timeout, _ref, waiting_pid} = v}, nq} ->
        if Process.alive?(waiting_pid) do
          send(pid, {:queue_response, v})

          if :queue.is_empty(nq) do
            {:noreply,
             %{
               state
               | queues: Map.delete(queues, location)
             }}
          else
            {:noreply, %{state | queues: Map.put(queues, location, nq)}}
          end
        else
          handle_cast({:get_next, location, pid}, %{state | queues: Map.put(queues, location, nq)})
        end

      {:empty, _} ->
        {:noreply,
         %{
           state
           | waiting: add_to_q(waiting, location, pid),
             queues: Map.delete(queues, location)
         }}
    end
  end

  def handle_cast(
        {:add_to_queue, location,
         {_query, _method, _argument, _timeout, ref, waiting_pid} = payload},
        %{queues: queues, waiting: waitings} = state
      ) do
    waiting = Map.get(waitings, location, :queue.new())

    case :queue.out(waiting) do
      {{:value, v}, nq} ->
        if Process.alive?(v) do
          send(v, {:queue_response, payload})

          if :queue.is_empty(nq) do
            {:noreply,
             %{
               state
               | waiting: Map.delete(waitings, location)
             }}
          else
            {:noreply, %{state | waiting: Map.put(waitings, location, nq)}}
          end
        else
          handle_cast({:add_to_queue, location, payload}, %{
            state
            | waiting: Map.put(waitings, location, nq)
          })
        end

      {:empty, _} ->
        if :queue.len(waiting) < @max_queue_size do
          {:noreply,
           %{
             state
             | queues: add_to_q(queues, location, payload),
               waiting: Map.delete(waitings, location)
           }}
        else
          send(waiting_pid, {ref, :queue_too_big})

          {:noreply,
           %{
             state
             | waiting: Map.delete(waitings, location)
           }}
        end
    end
  end
end
