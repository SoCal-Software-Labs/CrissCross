defmodule CrissCross.Utils do
  defmodule DecoderError do
    defexception message: "error decoding BERT"
  end

  defmodule MissingHashError do
    defexception message: "could not find hash locally"
  end

  @crlf_iodata [?\r, ?\n]

  import CrissCrossDHT.Server.Utils, only: [encrypt: 2, decrypt: 2]

  defdelegate hash(h), to: CrissCrossDHT.Server.Utils, as: :hash

  defdelegate encode_human(item), to: CrissCrossDHT.Server.Utils, as: :encode_human
  defdelegate decode_human!(item), to: CrissCrossDHT.Server.Utils, as: :decode_human!
  defdelegate serialize_bert(item), to: :erlang, as: :term_to_binary
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

  @compile {:inline, encode_redis_string: 1}
  def encode_redis_string(item) do
    [?$, Integer.to_string(byte_size(item)), @crlf_iodata, item, @crlf_iodata]
  end

  @compile {:inline, encode_redis_integer: 1}
  def encode_redis_integer(item) do
    [?:, Integer.to_string(item), @crlf_iodata]
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

      e ->
        e
    end
  end

  def encrypt_cluster_message(cluster_id, msg) do
    case get_cluster_secret(cluster_id) do
      %{cypher: cypher} ->
        encrypt(cypher, msg)

      e ->
        e
    end
  end

  def get_cluster_secret(cluster_id) do
    Agent.get(CrissCross.ClusterConfigs, fn clusters -> Map.get(clusters, cluster_id) end)
  end
end
