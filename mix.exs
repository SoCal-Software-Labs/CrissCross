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
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:cubdb, path: "../cubdb"},
      {:jason, "~> 1.3.0"},
      {:tesla, "~> 1.4.0"},
      {:finch, "~> 0.10.0"},
      {:redix, "~> 1.1"},
      {:benchee, "~> 1.0"},
      {:b58, "~> 1.0.2"},
      {:cachex, "~> 3.4.0"},
      {:crisscrossdht, path: "../MlDHT"},
      {:rustler, "~> 0.23.0"},
      {:yaml_elixir, "~> 2.8"}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
