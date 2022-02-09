defmodule CrissCross.ConnectionCache do
  def get_conn(cluster, {a, b, c, d} = remote_ip, port) do
    IO.inspect({remote_ip, port})

    r =
      Cachex.fetch(:connection_cache, {remote_ip, port, cluster}, fn _ ->
        case Redix.start_link(host: "#{a}.#{b}.#{c}.#{d}", port: port) do
          {:ok, conn} -> {:commit, conn}
          e -> {:ignore, e}
        end
      end)

    case r do
      {:ignore, e} ->
        e

      {_, conn} ->
        if Process.alive?(conn) do
          {:ok, conn}
        else
          Cachex.del(:connection_cache, {remote_ip, port, cluster})
          get_conn(cluster, remote_ip, port)
        end
    end
  end
end
