defmodule CrissCross.Store.CachedRPC do
  @moduledoc false

  # `CubDB.Store.CachedRPC` is an implementation of the `Store` protocol

  defstruct conns: nil, local_store: nil, tree_hash: nil
  alias CrissCross.Store.CachedRPC
  alias CrissCross.Utils

  def create(conns, tree_hash, local) do
    {:ok, %CachedRPC{conns: conns, tree_hash: tree_hash, local_store: local}}
  end
end

defimpl CubDB.Store, for: CrissCross.Store.CachedRPC do
  alias CrissCross.Store.CachedRPC
  import CrissCross.Utils
  alias CrissCross.Utils
  alias CrissCross.ConnectionCache
  import CrissCrossDHT.Server.Utils, only: [encrypt: 2, decrypt: 2]

  require Logger

  def identifier(local) do
    local.tree_hash
  end

  def clean_up(_store, _cpid, _btree) do
    :ok
  end

  def clean_up_old_compaction_files(_store, _pid) do
    :ok
  end

  def start_cleanup(%CachedRPC{}) do
    {:ok, nil}
  end

  def next_compaction_store(r = %CachedRPC{}) do
    r
  end

  def put_node(%CachedRPC{local_store: local_store}, n) do
    CubDB.Store.put_node(local_store, n)
  end

  def put_header(%CachedRPC{local_store: local_store}, header) do
    CubDB.Store.put_header(local_store, header)
  end

  def sync(%CachedRPC{}), do: :ok

  def get_node(%CachedRPC{conns: conns, local_store: local_store} = rpc, {_, hash_loc} = location) do
    try do
      CubDB.Store.get_node(local_store, location)
    rescue
      Utils.MissingHashError ->
        conns
        |> Enum.shuffle()
        |> Enum.filter(fn conn ->
          Cachex.get(:blacklisted_ips, tuple(conn)) == {:ok, nil}
        end)
        |> Enum.reduce_while(nil, fn conn, acc ->
          case do_get(conn, location) do
            {:ok, value} when is_binary(value) ->
              case do_decrypt(conn, value) do
                real_value when is_binary(real_value) ->
                  if hash(real_value) == hash_loc do
                    v = deserialize_bert(real_value)
                    put_node(rpc, v)
                    {:halt, v}
                  else
                    Cachex.put!(:blacklisted_ips, tuple(conn), true)
                    Logger.error("Invalid Content Hash")
                    {:cont, acc}
                  end

                _ = e ->
                  Cachex.put!(:blacklisted_ips, tuple(conn), true)
                  Logger.error("Error with GET decrypt: #{inspect(e)}")
                  {:cont, acc}
              end

            {:ok, nil} ->
              {:cont, acc}

            _ = e ->
              Cachex.put!(:blacklisted_ips, tuple(conn), true)
              Logger.error("Error with remote GET: #{inspect(e)}")
              {:cont, acc}
          end
        end)
        |> raise_if_nil(location)
    end
  end

  def raise_if_nil(nil, {_, location}), do: raise(Utils.MissingHashError, encode_human(location))
  def raise_if_nil(val, _location), do: val

  def get_latest_header(%CachedRPC{tree_hash: tree_hash} = local) do
    case tree_hash do
      nil ->
        nil

      header_loc ->
        {{0, header_loc}, get_node(local, {0, header_loc})}
    end
  end

  def close(%CachedRPC{conns: conns, local_store: local_store}) do
    Enum.each(conns, fn conn ->
      ConnectionCache.return(conn)
    end)

    CubDB.Store.close(local_store)
  end

  def blank?(%CachedRPC{tree_hash: tree_hash}) do
    tree_hash == nil
  end

  def open?(%CachedRPC{local_store: local_store}) do
    Process.alive?(local_store)
  end

  def do_get({:unencrypted, conn, _}, {_, location}) do
    Redix.command(conn, ["GET", location])
  end

  def do_get({:encrypted, conn, secret, _}, {_, location}) do
    payload = encrypt(secret, location)
    Redix.command(conn, ["GET", payload])
  end

  def do_decrypt({:unencrypted, _conn, _}, msg) do
    msg
  end

  def do_decrypt({:encrypted, _conn, secret, _}, msg) do
    decrypt(msg, secret)
  end

  def tuple({:unencrypted, _, t}) do
    t
  end

  def tuple({:encrypted, _, _, t}) do
    t
  end
end
