defmodule CrissCross.VPNConfig do
  use Agent

  @doc """
  Starts a new bucket.
  """
  def start_link(desinations) do
    Agent.start_link(
      fn ->
        Enum.map(desinations, fn destination -> {destination, true} end)
        |> Enum.into(%{})
      end,
      name: __MODULE__
    )
  end

  def get_vpn_key(cluster, name, host, port) do
    Agent.get(__MODULE__, &Map.get(&1, {cluster, name, host, port}, nil))
  end

  def allow_use(cluster, name, host, port, private_key, public_token) do
    Agent.update(
      __MODULE__,
      &Map.put(&1, {cluster, name, host, port}, {public_token, private_key})
    )
  end

  def disallow_use(cluster, name, host, port) do
    Agent.update(__MODULE__, &Map.delete(&1, {cluster, name, host, port}))
  end
end
