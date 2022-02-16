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
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:cubdb, github: "SoCal-Software-Labs/cubdb"},
      {:jason, "~> 1.3.0"},
      {:redix, "~> 1.1"},
      {:benchee, "~> 1.0", only: :dev},
      {:b58, "~> 1.0.2"},
      {:cachex, "~> 3.4.0"},
      {:ex_multihash, "~> 2.0"},
      {:ex_schnorr,
       github: "hansonkd/ex_schnorr", ref: "c1aedaa7f38d5df49b76c4e04cfd8c666732deea"},
      {:crisscrossdht,
       github: "SoCal-Software-Labs/CrissCrossDHT",
       ref: "a1f59d049905d69e443493b9f8436c4dbc7fe1e4"},
      # {:crisscrossdht, path: "../MlDHT"},
      {:rustler, "~> 0.23.0"},
      {:yaml_elixir, "~> 2.8"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
