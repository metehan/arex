defmodule Arex.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/m/exarcade"

  def project do
    [
      app: :arex,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      description: description(),
      source_url: @source_url,
      package: package(),
      test_coverage: [summary: [threshold: 82.0]],
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :inets, :ssl]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end

  defp description do
    "ArcadeDB-native Elixir client with tenant/scope-aware record, graph, KV, TimeSeries, and vector helpers."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      maintainers: ["m"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => "https://hexdocs.pm/arex",
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(.formatter.exs CHANGELOG.md LICENSE README.md docs lib mix.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Arex",
      source_url: @source_url,
      source_ref: "v#{@version}",
      homepage_url: "https://hexdocs.pm/arex",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/getting_started.md",
        "docs/records_and_queries.md",
        "docs/graph_and_schema.md",
        "docs/runtime_behavior.md",
        "docs/arex/skill.md"
      ],
      groups_for_extras: [
        Overview: ["README.md"],
        Guides: [
          "docs/getting_started.md",
          "docs/records_and_queries.md",
          "docs/graph_and_schema.md",
          "docs/runtime_behavior.md",
          "docs/arex/skill.md"
        ],
        Operations: ["CHANGELOG.md"]
      ],
      groups_for_modules: [
        Core: [Arex, Arex.Query, Arex.Command, Arex.Record, Arex.KV, Arex.TimeSeries, Arex.Vector],
        Graph: [Arex.Vertex, Arex.Edge],
        Schema: [Arex.Schema, Arex.Database],
        Support: [Arex.Error, Arex.Options, Arex.Http, Arex.Sql]
      ]
    ]
  end
end
