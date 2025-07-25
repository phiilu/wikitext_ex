defmodule WikitextEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/phiilu/wikitext_ex"

  def project do
    [
      app: :wikitext_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nimble_parsec, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    A MediaWiki wikitext parser for Elixir that converts wikitext markup 
    into structured AST nodes, supporting templates, links, formatting, tables, 
    and other wikitext elements commonly found in MediaWiki content.
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
