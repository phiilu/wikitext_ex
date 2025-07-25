defmodule WikitextEx.WikitextFixtures do
  @moduledoc """
  Test helper for loading wikitext fixture files.
  """

  @fixtures_path Path.join([__DIR__, "support", "fixtures", "wikitext"])

  @doc """
  Load a wikitext fixture file by name.

  ## Examples
      iex> load_fixture("products_table")
      "{| style=\"margin:auto; text-align: center..."
  """
  def load_fixture(name) do
    path = Path.join(@fixtures_path, "#{name}.wikitext")

    case File.read(path) do
      {:ok, content} ->
        content

      {:error, reason} ->
        raise "Failed to load fixture '#{name}': #{reason}. Available fixtures: #{list_fixtures()}"
    end
  end

  @doc """
  List all available fixture names (without .wikitext extension).
  """
  def list_fixtures do
    case File.ls(@fixtures_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".wikitext"))
        |> Enum.map(&String.replace(&1, ".wikitext", ""))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end
end
