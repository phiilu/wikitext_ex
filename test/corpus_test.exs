defmodule WikitextEx.CorpusTest do
  @moduledoc """
  WikitextEx against a reference generated outside the suite: real pages,
  whose content cannot ship with the library, or a fuzz batch.

      mise run corpus path/to/pages   # a directory of `.wikitext` files
      mise run fuzz [seed] [count]    # generated inputs, `scripts/fuzz_inputs.py`

  Both generate the reference and run this module on it, through
  `WIKITEXT_CORPUS_REFERENCE`.
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
