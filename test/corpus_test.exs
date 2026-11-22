defmodule WikitextEx.CorpusTest do
  @moduledoc """
  WikitextEx against a corpus of real pages, for content that cannot ship with
  the library. Generate a reference for a directory of `.wikitext` files with

      python -I scripts/mwph_reference.py files path/to/pages corpus.json

  and run

      WIKITEXT_CORPUS_REFERENCE=corpus.json mix test --only corpus

  """
  use ExUnit.Case, async: true

  alias WikitextEx.Test.Reference

  @moduletag :corpus

  if path = System.get_env("WIKITEXT_CORPUS_REFERENCE") do
    @external_resource path

    for {reference, index} <-
          path
          |> Reference.load!()
          |> Enum.with_index(1) do
      @reference reference

      test "parses #{reference["name"]} (##{index}) as the reference does" do
        Reference.assert_tree(@reference)
      end

      test "writes #{reference["name"]} (##{index}) back to its input" do
        Reference.assert_round_trip(@reference)
      end
    end
  end
end
