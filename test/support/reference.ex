defmodule WikitextEx.Test.Reference do
  @moduledoc """
  Reads reference output generated from mwparserfromhell by
  `scripts/mwph_reference.py` and writes WikitextEx trees in the same shape.

  The reference is mwparserfromhell's tree, where every list marker is a node of
  its own followed by the line's content as siblings. WikitextEx groups a line's
  content into its list item, so each list item is written back out flat.
  Both sides merge adjacent text, as the split of a text node at a list item's
  line end is no difference between the two.
  """

  import ExUnit.Assertions

  @doc "The cases of a reference file."
  def load!(path) do
    path
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("cases")
  end

  @doc "Asserts that WikitextEx parses the case's input into its reference tree."
  def assert_tree(reference) do
    {:ok, nodes} = WikitextEx.parse(reference["input"])
    assert tree(nodes) == normalize(reference["tree"])
  end

  @doc "Asserts that the case's input, parsed and written back, is unchanged."
  def assert_round_trip(reference) do
    {:ok, nodes} = WikitextEx.parse(reference["input"])
    assert WikitextEx.to_wikitext(nodes) == reference["input"]
  end

  # A reference tree with adjacent text merged.
  defp normalize(nodes) when is_list(nodes) do
    nodes
    |> Enum.map(fn
      %{"children" => children} = node -> %{node | "children" => normalize(children)}
      text when is_binary(text) -> text
    end)
    |> merge_text()
  end

  # A WikitextEx tree in the reference's shape.
  defp tree(nodes) when is_list(nodes) do
    nodes
    |> Enum.flat_map(&flatten/1)
    |> merge_text()
  end

  defp flatten(text) when is_binary(text), do: [text]

  defp flatten({:list_item, %{marker: marker}, children}) do
    markers =
      for <<char <- marker>> do
        %{"type" => "list_item", "meta" => %{"marker" => <<char>>}, "children" => []}
      end

    markers ++ Enum.flat_map(children, &flatten/1)
  end

  defp flatten({type, meta, children}) do
    [%{"type" => Atom.to_string(type), "meta" => json(meta), "children" => tree(children)}]
  end

  defp json(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json(value)} end)

  defp json(list) when is_list(list), do: Enum.map(list, &json/1)

  defp json(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> json()
  end

  defp json(value), do: value

  defp merge_text([text, next | rest]) when is_binary(text) and is_binary(next),
    do: merge_text([text <> next | rest])

  defp merge_text([node | rest]), do: [node | merge_text(rest)]
  defp merge_text([]), do: []
end
