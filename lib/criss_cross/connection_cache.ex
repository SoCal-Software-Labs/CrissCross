defmodule CrissCross.ConnectionCache do
  @encrypt true

  import CrissCross.Utils
  import CrissCrossDHT.Server.Utils, only: [encrypt: 2]

  def get_conn(cluster, {a, b, c, d} = remote_ip, port) do
    r =
      Cachex.fetch(:connection_cache, {remote_ip, port, cluster}, fn _ ->
        case Redix.start_link(
               host: "#{a}.#{b}.#{c}.#{d}",
               port: port,
               username: cluster,
               password: ""
             ) do
          {:ok, conn} ->
            if @encrypt do
              {public_key, private_key} = :crypto.generate_key(:ecdh, :x25519)

              case Redix.command(conn, ["EXCHANGEKEY", public_key]) do
                {:ok, [other_public, token]} ->
                  secret = :crypto.compute_key(:ecdh, other_public, private_key, :x25519)
                  response = encrypt_cluster_message(cluster, token)
                  cluster_id_reponse = encrypt(secret, cluster)

                  case Redix.command(conn, ["VERIFY", cluster_id_reponse, response]) do
                    {:ok, "OK"} ->
                      {:commit, {:encrypted, conn, secret}}

                    e ->
                      {:ignore, e}
                  end

                e ->
                  {:ignore, e}
              end
            else
              {:commit, {:unencrypted, conn}}
            end

          e ->
            {:ignore, e}
        end
      end)

    case r do
      {:ignore, e} ->
        e

      {_, wrapped} ->
        conn =
          case wrapped do
            {:unencrypted, conn} -> conn
            {:encrypted, conn, _secret} -> conn
          end

        if Process.alive?(conn) do
          case Redix.command(conn, ["PING"]) do
            {:ok, "PONG"} ->
              {:ok, wrapped}

            _ ->
              {:error, "Remote connection not responding"}
          end
        else
          Cachex.del(:connection_cache, {remote_ip, port, cluster})
          get_conn(cluster, remote_ip, port)
        end
    end
  end
end
