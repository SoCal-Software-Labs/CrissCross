defmodule CrissCross.MixProject do
  use Mix.Project

  def project do
    [
      app: :criss_cross,
      version: "0.1.0",
      elixir: "~> 1.12",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {CrissCross.Application, []},
      extra_applications: [:logger, :crypto, :inets]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:cubdb, github: "SoCal-Software-Labs/cubdb"},
      {:jason, "~> 1.3.0"},
      {:redix, github: "SoCal-Software-Labs/safe-redix"},
      {:benchee, "~> 1.0", only: :dev},
      {:b58, "~> 1.0.2"},
      {:cachex, "~> 3.4.0"},
      {:ex_multihash, "~> 2.0"},
      {:ex_schnorr, "~> 0.1.0"},
      {:ex_p2p,
       github: "SoCal-Software-Labs/ExP2P", ref: "9014adc30e44e37a5b22874886d345e59b74f328"},
      # {:ex_p2p, path: "../ex_p2p"},
      {:criss_cross_dht,
       github: "SoCal-Software-Labs/CrissCrossDHT",
       ref: "fe40a2db1d2eb16d4db2d9640e4917dd34850b3e"},
      # {:criss_cross_dht, path: "../MlDHT"},
      {:rustler, "~> 0.23.0"},
      {:yaml_elixir, "~> 2.8"},
      {:sorted_set_kv, "~> 0.1.2"},
      {:hammer, "~> 6.0"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
