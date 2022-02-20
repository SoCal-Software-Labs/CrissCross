defmodule CrissCross.Store.CacheStore do
  @moduledoc false

  # `CubDB.Store.CacheStore` is an implementation of the `Store` protocol
  # intended for test purposes only. It is backed by a map, but supports all the
  # operations of a `CubDB.Store`. It allows some tests to be simpler and faster
  # by avoid using the file system.

  defstruct agent: nil
  alias CrissCross.Store.CacheStore

  @type t :: %CacheStore{}

  @spec create() :: {:ok, t} | {:error, term}

  def create do
    {:ok, %CacheStore{}}
  end
end

defimpl CubDB.Store, for: CrissCross.Store.CacheStore do
  alias CrissCross.Store.CacheStore
  alias CrissCross.Utils
  import CrissCross.Utils

  def identifier(_local) do
    "Cache"
  end

  def clean_up(_store, _cpid, _btree) do
    :ok
  end

  def clean_up_old_compaction_files(_store, _pid) do
    :ok
  end

  def start_cleanup(%CacheStore{}) do
    {:ok, nil}
  end

  def next_compaction_store(%CacheStore{}) do
    CacheStore.create()
  end

  def put_node(%CacheStore{}, n) do
    loc = hash(:erlang.term_to_binary(n))
    {:ok, _} = Cachex.put(:node_cache, loc, n)
    loc
  end

  def put_header(%CacheStore{} = c, header) do
    loc = put_node(c, header)
    {0, loc}
  end

  def sync(%CacheStore{}), do: :ok

  def get_node(%CacheStore{}, {0, location}) do
    case Cachex.get(:node_cache, location) do
      {:ok, nil} -> raise Utils.MissingHashError, location
      {:ok, h} when is_binary(h) -> h
      e -> e
    end
  end

  def get_latest_header(%CacheStore{}) do
    nil
  end

  def close(%CacheStore{}) do
    :ok
  end

  def blank?(%CacheStore{}) do
    true
  end

  def open?(%CacheStore{}) do
    false
  end
end
