defmodule WikitextEx.MixProject do
  use Mix.Project

  @version "0.1.1"

  # Read by both auditors: `mix hex.audit` through :hex below, `mix deps.audit`
  # through the deps.audit.check alias.
  @ignored_advisories []
  @source_url "https://github.com/phiilu/wikitext_ex"

  def project do
    [
      app: :wikitext_ex,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      hex: [ignore_advisories: @ignored_advisories],
      dialyzer: [plt_add_apps: [:mix, :ex_unit], plt_local_path: "priv/plts"],
      description: description(),
      package: package(),
      docs: docs(),
      name: "WikitextEx",
      source_url: @source_url
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "== 1.7.19", only: [:dev, :test], runtime: false},
      {:credo_unnecessary_reduce, "== 0.4.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "== 1.4.9", only: [:dev], runtime: false},
      {:ex_dna, "== 1.5.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:ex_slop, "== 0.4.5", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "== 0.7.1", only: [:dev, :test], runtime: false},
      {:mix_audit, "== 2.1.5", only: [:dev, :test], runtime: false},
      {:quokka, "== 2.13.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "format-lint": ["format", "compile --warnings-as-errors", "credo --strict"],
      "deps.audit.check":
        "deps.audit --ignore-advisory-ids #{Enum.join(@ignored_advisories, ",")}"
    ]
  end

  defp description do
    """
    A MediaWiki wikitext parser in pure Elixir: wikitext to a tree of tuples
    and back, losslessly.
    """
  end

  defp package do
    [
      name: "wikitext_ex",
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["Florian Kapfenberger <florian@kapfenberger.me>"]
    ]
  end

  defp docs do
    [
      name: "WikitextEx",
      main: "WikitextEx",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
