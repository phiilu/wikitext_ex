defmodule WikitextEx.ConformanceTest do
  @moduledoc """
  WikitextEx parses mwparserfromhell's tokenizer suite, and edge cases found
  by fuzzing, into the tree mwparserfromhell builds, and writes every tree back
  to its input.

  The suite's inputs are mwparserfromhell's (MIT); the expected trees are its C
  tokenizer's, at the version `scripts/mwph_reference.py` pins, and
  `mise run reference:suite` regenerates them. The edge cases are in
  `test/fixtures/edge_cases`.

  Where mwparserfromhell's C and Python tokenizers disagree, the C one is the
  reference. Its C tokenizer stops reading at `NUL`, where WikitextEx reads on,
  so no reference input holds one.

  A difference from the reference becomes an edge case: add a `.wikitext` file
  to `test/fixtures/edge_cases`, regenerate `edge_cases.json` with
  `mise run reference:edge-cases`, and see it fail before fixing it.
  """
  use ExUnit.Case, async: true

  alias WikitextEx.Test.Reference

  @suite "test/fixtures/mwparserfromhell/conformance.json"
  @edge_cases "test/fixtures/edge_cases.json"
  @external_resource @suite
  @external_resource @edge_cases

  references =
    @suite
    |> Reference.load!()
    |> Enum.group_by(
      &(&1["name"]
        |> String.split(":")
        |> hd())
    )
    |> Map.put("edge_cases", Reference.load!(@edge_cases))

  for {group, cases} <- references do
    describe group do
      @describetag group: group

      for {reference, index} <- Enum.with_index(cases, 1) do
        @reference reference

        test "parses #{reference["name"]} (##{index}) as mwparserfromhell does" do
          Reference.assert_tree(@reference)
        end

        test "writes #{reference["name"]} (##{index}) back to its input" do
          Reference.assert_round_trip(@reference)
        end
      end
    end
  end
end
