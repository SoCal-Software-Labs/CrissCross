defmodule CrissCross.Store.MerkleStore do
  @moduledoc false

  # `CubDB.Store.MerkleStore` is an implementation of the `Store` protocol
  # intended for test purposes only. It is backed by a map, but supports all the
  # operations of a `CubDB.Store`. It allows some tests to be simpler and faster
  # by avoid using the file system.

  defstruct agent: nil
  alias CrissCross.Store.MerkleStore

  @type t :: %MerkleStore{agent: pid}

  @spec create() :: {:ok, t} | {:error, term}

  def create do
    with {:ok, pid} <- Agent.start_link(fn -> {%{}, nil} end) do
      {:ok, %MerkleStore{agent: pid}}
    end
  end
end

defimpl CubDB.Store, for: CrissCross.Store.MerkleStore do
  alias CrissCross.Store.MerkleStore
  import CrissCross.Utils

  def identifier(_local) do
    "Merkle"
  end

  def clean_up(_store, _cpid, _btree) do
    :ok
  end

  def clean_up_old_compaction_files(_store, _pid) do
    :ok
  end

  def start_cleanup(%MerkleStore{}) do
    {:ok, nil}
  end

  def next_compaction_store(%MerkleStore{}) do
    MerkleStore.create()
  end

  def put_node(%MerkleStore{agent: agent}, node) do
    Agent.get_and_update(
      agent,
      fn {map, latest_header_loc} ->
        loc = hash(:erlang.term_to_binary(node))
        {{0, loc}, {Map.put(map, loc, node), latest_header_loc}}
      end,
      :infinity
    )
  end

  def put_header(%MerkleStore{agent: agent}, header) do
    Agent.get_and_update(
      agent,
      fn {map, _} ->
        loc = hash(:erlang.term_to_binary(header))
        {{0, loc}, {Map.put(map, loc, header), loc}}
      end,
      :infinity
    )
  end

  def sync(%MerkleStore{}), do: :ok

  def get_node(%MerkleStore{agent: agent}, {0, location}) do
    case Agent.get(
           agent,
           fn {map, _} ->
             Map.fetch(map, location)
           end,
           :infinity
         ) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  def get_latest_header(%MerkleStore{agent: agent}) do
    Agent.get(
      agent,
      fn
        {_, nil} -> nil
        {map, header_loc} -> {{0, header_loc}, Map.get(map, header_loc)}
      end,
      :infinity
    )
  end

  def close(%MerkleStore{agent: agent}) do
    Agent.stop(agent, :normal, :infinity)
  end

  def blank?(%MerkleStore{agent: agent}) do
    Agent.get(
      agent,
      fn
        {_, nil} -> true
        _ -> false
      end,
      :infinity
    )
  end

  def open?(%MerkleStore{agent: agent}) do
    Process.alive?(agent)
  end
end
