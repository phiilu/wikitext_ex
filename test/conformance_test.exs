defmodule WikitextEx.ConformanceTest do
  @moduledoc """
  WikitextEx parses mwparserfromhell's tokenizer suite, and edge cases found
  by fuzzing, into the tree mwparserfromhell builds, and writes every tree back
  to its input.

  The suite's inputs are mwparserfromhell's (MIT); the expected trees were
  generated from mwparserfromhell 0.7.2, its C tokenizer, with
  `scripts/mwph_reference.py`. The edge cases are in `test/fixtures/edge_cases`.
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
          {:ok, nodes} = WikitextEx.parse(@reference["input"])

          assert Reference.tree(nodes) == Reference.normalize(@reference["tree"])
        end

        test "writes #{reference["name"]} (##{index}) back to its input" do
          {:ok, nodes} = WikitextEx.parse(@reference["input"])

          assert WikitextEx.to_wikitext(nodes) == @reference["input"]
        end
      end
    end
  end
end
