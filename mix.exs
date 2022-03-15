defmodule CrissCross.MixProject do
  use Mix.Project

  def project do
    [
      app: :crisscross,
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
      crisscross: [
        steps:
          if System.get_env("BURRITO_TARGET") == "none" do
            [:assemble]
          else
            [:assemble, &Burrito.wrap/1]
          end,
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
       github: "SoCal-Software-Labs/ExP2P", ref: "2104c37904e89f32ea84418fd002d19efe4c4bfb"},
      # {:ex_p2p, path: "../ex_p2p", override: true},
      {:criss_cross_dht,
       github: "SoCal-Software-Labs/CrissCrossDHT",
       ref: "f1098f093c44f39f2179c86ee639f3e4b9c5e51f"},
      # {:criss_cross_dht, path: "../MlDHT"},
      {:rustler, "~> 0.23.0"},
      {:yaml_elixir, "~> 2.8"},
      {:sorted_set_kv, "~> 0.1.3"},
      {:hammer, "~> 6.0"},
      {:burrito,
       github: "SoCal-Software-Labs/burrito", ref: "a5a418467f17007175333f54082c145287f5cb3e"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
