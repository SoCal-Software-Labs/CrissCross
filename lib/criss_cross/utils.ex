defmodule CrissCross.Utils do
  @crlf_iodata [?\r, ?\n]

  defdelegate serialize_bert(item), to: :erlang, as: :term_to_binary

  @compile {:inline, deserialize_bert: 1}
  def deserialize_bert(item) do
    :erlang.binary_to_term(item, [:safe])
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
end
