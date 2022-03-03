defmodule CrissCross.MixProject do
  use Mix.Project

  def project do
    [
      app: :criss_cross,
      version: "0.1.0",
      releases: releases(),
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

  def releases do
    [
      criss_cross: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos: [os: :darwin, cpu: :x86_64],
            linux: [os: :linux, cpu: :x86_64],
            windows: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
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
      {:ex_schnorr, "~> 0.1.1"},
      {:ex_p2p,
       github: "SoCal-Software-Labs/ExP2P", ref: "3db87ad2206ad8c4327ba84cdb1c3d9f189a4097"},
      # {:ex_p2p, path: "../ex_p2p"},
      {:criss_cross_dht,
       github: "SoCal-Software-Labs/CrissCrossDHT",
       ref: "38fd4448c1fd6dc8e1e1bee57ce9d6942bc6c10c"},
      # {:criss_cross_dht, path: "../MlDHT"},
      {:rustler, "~> 0.23.0"},
      {:yaml_elixir, "~> 2.8"},
      {:sorted_set_kv, "~> 0.1.2"},
      {:hammer, "~> 6.0"},
      {:burrito, github: "burrito-elixir/burrito"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
