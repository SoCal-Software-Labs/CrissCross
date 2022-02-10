defmodule CrissCross.Application do
  use Application

  require Logger

  alias CrissCrossDHT.Server.Utils

  @cypher "DEoGUJcJCMKVuHXAmjgNyU6cCrPcHFymd6c7o5i9yVzT"
  @public_key "-----BEGIN RSA PUBLIC KEY-----\nMIIBCgKCAQEAzCBvDU/9sz1tPMonJMu9khHk0VaMet8bgJMShHpSYM7ul0yfihz1\nL7CU5ppZF+v2tr+xFt2aSSqFf4irpbOOuBryBPZUDBgQSIz/JpLLMBmioUq0EZfZ\nfmG8XU1lygKsP+MoyQJ5umzt4i9e9mMV+LVwZmY88dhcFvDWkT0MG9yrYjX65L8L\nja4mXZWLAIZoUFaJ617SxeoP0Bv5bmAgH666T8q66l4FTagPHX/komRkQhvYH4FD\ncfTr/Z0mnSCuNreA2vJpXupekfgEPMwXz3zlPPQ7f4E+mqUO+p+XYUE7JBlTggYD\ncpEzPUt7Wk0gbe9K+ez7zDojoGkSxhc3KwIDAQAB\n-----END RSA PUBLIC KEY-----\n\n"
  @private_key "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEAzCBvDU/9sz1tPMonJMu9khHk0VaMet8bgJMShHpSYM7ul0yf\nihz1L7CU5ppZF+v2tr+xFt2aSSqFf4irpbOOuBryBPZUDBgQSIz/JpLLMBmioUq0\nEZfZfmG8XU1lygKsP+MoyQJ5umzt4i9e9mMV+LVwZmY88dhcFvDWkT0MG9yrYjX6\n5L8Lja4mXZWLAIZoUFaJ617SxeoP0Bv5bmAgH666T8q66l4FTagPHX/komRkQhvY\nH4FDcfTr/Z0mnSCuNreA2vJpXupekfgEPMwXz3zlPPQ7f4E+mqUO+p+XYUE7JBlT\nggYDcpEzPUt7Wk0gbe9K+ez7zDojoGkSxhc3KwIDAQABAoIBAHcNZ5edEruKVP7C\nbGgSiCL8WrcZQl+bZj/sBz3K1ebuactGfjogP4Qr+fwxA0tnbQIS9Sb/4i9QJIJI\nZMwE2HVaCdOJE2XmVwDpcxq9PNJ18RsfJbypEsmaGTFVpctXGb09MJlj3zkytN9Z\nf4o2KidfMwoWEO+An90lZA9bSoeodbabuaufHiNd2Llx67U67HzmsJhUYrg38ZC5\nMWexapTo4oS9cY4zQN3LwLNyawnekw8oSOOefTr0hnI33xQPZSrH/VCkXNpCUEer\nYigRJGi4GlThtFRnhNcniaRmUs3/EMI85SDvPbtpOSD87iV/uXZBcWfbpJe4NybC\ncZnhy0ECgYEA90t3t/H+Abyt81qgx/r4Fl1zLYSkCuIkllXBQJvrrGuQyLip4/k5\nYvfjUu0gQyaVoLj2oGKlHPXE3xYLK9yJmewRNV7eBmUpfCCjUROFSzCH4SP6u2C0\naG/9DUelQw3pAnMzgXt7ePB6Iw0hqKejDZrJPau7DQDDE1TeL5paCYsCgYEA00/z\nXUtG3sLqfDhrEOt1RfD2+YaAu6ESptX94TxdP/aBrIOy8A9j9XpaXkEwthcLuawL\nQEVjAZsBNIP5yFxI3t7wUL6mDE4nm5btKDYKQc8Fmv/48ynHRqdqXSXSHbLD62SH\nLM/Tli13jRGrSRnOq00T9R5eG1MEkfI6FESw/OECgYBbSu79Z0bAWWlWR4THjuz7\nRLB6g1cT9XxQS4Q2V9lfI66lixac5Kq80IqJWKTqZVojpWTWvNP7pvdw6/Bf1uCt\nhCquK0GH1tzDyEDCc5Rnt5jSErhDaGXxkDY5KtPlt0Ln9qNzD6T7druAKR7d5lUZ\ndqUIMVeyay+Y+WG07SSEFQKBgQCLCF+nUpAeoUCG2tgXGdTfX9wf8U9iJGiRPNr+\nBymTnC1VxJFHQdkS+p3axim2pRMh5wDAGOc7dzEjzHHcUlvfx+92MPovvnxw8qy3\neFbnVb7qbODvnN1wr1ZcUzYcNDKT/mCyK0ub0+6E8sswHbrNGrm23XQtpkGrhSSR\nkWCiAQKBgQDtGPigKl4j61FPgTITeNoG87mTWx7YE5L6AAVjIzH4YiLMsiSL6Cis\nt+NEeIO8O0JAULZdf9jZM1kaV9oGopBUErlcJKfhAndYeWbN2hA0lpPimfCMFaV8\n+9lG3KCkDZJClZkabPK82euAiDDPBWo3MxAeRxPghbIeBftNDRjhzw==\n-----END RSA PRIVATE KEY-----\n\n"

  @cluster_name Utils.encode_human(Utils.hash(Utils.combine_to_sign([@cypher, @public_key])))

  @process_name CrissCrossDHT.Server.Worker

  @default_udp 35000

  def start(_type, _args) do
    node_id = Utils.gen_node_id()

    CrissCrossDHT.Registry.start()

    external_tcp_port = System.get_env("EXTERNAL_TCP_PORT", "35001") |> String.to_integer()
    internal_tcp_port = System.get_env("INTERNAL_TCP_PORT", "35002") |> String.to_integer()
    redis_url = System.get_env("REDIS_URL", "redis://localhost:6379")

    bootstrap_nodes =
      System.get_env(
        "BOOTSTRAP_NODES",
        "udp://8thbnFn4HZ24vVojR5qV6jsLCoqMaeBAVSxioBLmzGzC@localhost:#{@default_udp}"
      )
      |> String.split(",")
      |> Enum.map(fn c ->
        case URI.parse(c) do
          %URI{scheme: "udp", port: port, host: host, userinfo: userinfo}
          when is_binary(userinfo) ->
            %{node_id: userinfo, host: host, port: port || @default_udp}

          _ ->
            raise "Invalid BOOTSTRAP_NODES config"
        end
      end)

    dht_config = %{
      port: System.get_env("EXTERNAL_UDP_PORT", "#{@default_udp}") |> String.to_integer(),
      ipv4: true,
      ipv6: false,
      clusters: %{
        @cluster_name => %{secret: @cypher, public_key: @public_key, private_key: @private_key}
      },
      bootstrap_nodes: bootstrap_nodes,
      k_bucket_size: 12,
      storage: {CrissCross.DHTStorage.DHTRedis, [redis_opts: redis_url]}
    }

    children = [
      Supervisor.child_spec({Cachex, name: :connection_cache}, id: :connection_cache),
      Supervisor.child_spec({Cachex, name: :node_cache}, id: :node_cache),
      {Task.Supervisor, name: CrissCross.TaskSupervisor},
      Supervisor.child_spec(
        {Task, fn -> CrissCross.ExternalRedis.accept(external_tcp_port, redis_url) end},
        restart: :permanent,
        id: :external_redis
      ),
      Supervisor.child_spec(
        {Task,
         fn ->
           CrissCross.InternalRedis.accept(internal_tcp_port, external_tcp_port, redis_url)
         end},
        restart: :permanent,
        id: :internal_redis
      ),
      {CrissCrossDHT.Supervisor, node_id: node_id, worker_name: @process_name, config: dht_config}
    ]

    Logger.debug("External serving on: #{external_tcp_port}")
    Logger.debug("Internal serving on: #{internal_tcp_port}")
    ## Start the main supervisor
    opts = [strategy: :one_for_one, name: CrissCross.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
