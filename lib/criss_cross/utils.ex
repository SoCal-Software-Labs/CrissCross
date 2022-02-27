defmodule CrissCross.Utils do
  defmodule DecoderError do
    defexception message: "error decoding BERT"
  end

  defmodule MissingHashError do
    defexception message: "could not find hash locally"
  end

  defmodule MissingClusterError do
    defexception message: "cluster not configured"
  end

  defmodule MissingVarError do
    defexception message: "var is missing"
  end

  defmodule DNSResolutionError do
    defexception message: "var is missing"
  end

  defmodule HTTPResolutionError do
    defexception message: "http resource not resolved"
  end

  defmodule MaxTransferExceeded do
    defexception message: "max size of transfer exceeded"
  end

  defmodule MulticodecError do
    defexception message: "invalid multicodec"
  end

  @crlf_iodata [?\r, ?\n]

  import CrissCrossDHT.Server.Utils, only: [encrypt: 2, decrypt: 2]

  defdelegate hash(h), to: CrissCrossDHT.Server.Utils, as: :hash

  defdelegate encode_human(item), to: CrissCrossDHT.Server.Utils, as: :encode_human
  defdelegate decode_human!(item), to: CrissCrossDHT.Server.Utils, as: :decode_human!
  defdelegate serialize_bert(item), to: :erlang, as: :term_to_binary

  @compile {:inline, deserialize_bert: 1}
  def deserialize_bert(item) do
    try do
      :erlang.binary_to_term(item, [:safe])
    rescue
      ArgumentError ->
        raise DecoderError
    end
  end

  @compile {:inline, redis_ok: 0}
  def redis_ok() do
    "+OK\r\n"
  end

  @compile {:inline, redis_nil: 0}
  def redis_nil() do
    "$-1\r\n"
  end

  @compile {:inline, encode_redis_string: 1}
  def encode_redis_string(item) do
    [?$, Integer.to_string(byte_size(item)), @crlf_iodata, item, @crlf_iodata]
  end

  @compile {:inline, encode_redis_error: 1}
  def encode_redis_error(item) do
    [?-, item, @crlf_iodata]
  end

  @compile {:inline, encode_redis_integer: 1}
  def encode_redis_integer(item) do
    [?:, Integer.to_string(item), @crlf_iodata]
  end

  def encode_redis_list_raw(acc) do
    [?*, Integer.to_string(length(acc)), @crlf_iodata, acc]
  end

  defdelegate encode_redis_list(item), to: Redix.Protocol, as: :pack

  def new_challenge_token() do
    :rand.seed(:exs64, :os.timestamp())

    s =
      Stream.repeatedly(fn -> :rand.uniform(255) end)
      |> Enum.take(40)
      |> :binary.list_to_bin()

    hash(s)
  end

  def decrypt_cluster_message(cluster_id, msg) do
    case get_cluster_secret(cluster_id) do
      %{cypher: cypher} ->
        decrypt(msg, cypher)

      _e ->
        raise MissingClusterError, cluster_id
    end
  end

  def encrypt_cluster_message(cluster_id, msg) do
    case get_cluster_secret(cluster_id) do
      %{cypher: cypher} ->
        encrypt(cypher, msg)

      _e ->
        raise MissingClusterError, cluster_id
    end
  end

  def cluster_max_transfer_size(cluster_id, msg) do
    case get_cluster_secret(cluster_id) do
      %{max_transfer: max_transfer} ->
        max_transfer

      _e ->
        0
    end
  end

  def get_cluster_secret(cluster_id) do
    CrissCrossDHT.ClusterWatcher.get_cluster(cluster_id)
  end

  def fetch_from_node_cache(location, cache_func) do
    ret = Cachex.fetch(:node_cache, location, cache_func)

    case ret do
      {_, val} when is_binary(val) ->
        Cachex.touch(:node_cache, location)
        ret

      _ ->
        ret
    end
  end

  @variant10 2
  @uuid_v4 4

  def make_job_ref() do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<u0::48, @uuid_v4::4, u1::12, @variant10::2, u2::62>>
  end
end
