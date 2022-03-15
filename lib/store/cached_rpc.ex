defmodule CrissCross.Store.CachedRPC do
  @moduledoc false

  # `CubDB.Store.CachedRPC` is an implementation of the `Store` protocol

  defstruct conns: nil,
            local_store: nil,
            tree_hash: nil,
            max_transfer: nil,
            transfered_pid: nil,
            cluster: nil

  alias CrissCross.Store.CachedRPC
  alias CrissCross.Utils

  def create(conns, cluster, tree_hash, local, max_transfer \\ nil) do
    {:ok, transfered_pid} = Agent.start_link(fn -> 0 end)

    {:ok,
     %CachedRPC{
       conns: conns,
       cluster: cluster,
       tree_hash: tree_hash,
       local_store: local,
       max_transfer: max_transfer,
       transfered_pid: transfered_pid
     }}
  end
end

defimpl CubDB.Store, for: CrissCross.Store.CachedRPC do
  alias CrissCross.Store.CachedRPC
  import CrissCross.Utils
  alias CrissCross.Utils
  alias CrissCross.PeerGroup
  import CrissCrossDHT.Server.Utils, only: [decrypt: 2]

  require Logger

  @get_timeout 10_000

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

  def get_node(
        %CachedRPC{conns: conns, cluster: cluster, local_store: local_store} = rpc,
        {_, hash_loc} = location
      ) do
    try do
      CubDB.Store.get_node(local_store, location)
    rescue
      Utils.MissingHashError ->
        PeerGroup.get_conns(conns, 5_000)
        |> Enum.shuffle()
        # |> Enum.filter(fn conn ->
        #   Cachex.get(:blacklisted_ips, tuple(conn)) == {:ok, nil}
        # end)
        |> Enum.reduce_while(nil, fn conn, acc ->
          case do_get(conn, cluster, location) do
            {:ok, real_value} when is_binary(real_value) ->
              if hash(real_value) == hash_loc do
                v = deserialize_bert(real_value)
                put_node(rpc, v)
                {:halt, v}
              else
                Cachex.put!(:blacklisted_ips, tuple(conn), true)
                Logger.error("Invalid Content Hash")
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
    |> add_to_transfered(rpc)
  end

  def add_to_transfered(result, %CachedRPC{
        transfered_pid: transfered_pid,
        max_transfer: max_transfer
      }) do
    if max_transfer != nil do
      new_bytes_transferred =
        Agent.get_and_update(transfered_pid, fn old ->
          new_size = old + :erlang.external_size(result)
          {new_size, new_size}
        end)

      if new_bytes_transferred > max_transfer do
        raise Utils.MaxTransferExceeded
      end
    end

    result
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

  def close(%CachedRPC{local_store: local_store}) do
    CubDB.Store.close(local_store)
  end

  def blank?(%CachedRPC{tree_hash: tree_hash}) do
    tree_hash == nil
  end

  def open?(%CachedRPC{local_store: local_store}) do
    Process.alive?(local_store)
  end

  def do_get({:quic, endpoint, conn, _}, cluster, {_, location}) do
    encrypted = encrypt_cluster_message(cluster, location)

    ret =
      ExP2P.bidirectional(
        endpoint,
        conn,
        serialize_bert(["GET", cluster, encrypted]),
        @get_timeout
      )

    case ret do
      {:ok, res_encrypted} ->
        case decrypt_cluster_message(cluster, res_encrypted) do
          decrypted when is_binary(decrypted) ->
            deserialize_bert(decrypted)

          e ->
            e
        end

      e ->
        e
    end
  end

  def do_decrypt({:quic, _conn, _}, msg) do
    msg
  end

  def do_decrypt({:encrypted, _conn, secret, _}, msg) do
    decrypt(msg, secret)
  end

  def tuple({:quic, _, _, t}) do
    t
  end
end
