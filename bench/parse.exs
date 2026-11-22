# Benchmarks parsing and writing back. `mix bench path/to/pages` adds a
# directory of `.wikitext` files as one more input.

section = """
== The Congress of Vienna ==
{{Infobox|name=Congress of Vienna|date=1814–1815|place=[[Vienna]]}}
The '''Congress of Vienna''' met from September 1814 to June 1815, chaired by \
[[Klemens von Metternich|Metternich]].<ref name="act">{{Citation|title=Final Act|year=1815}}</ref> \
It redrew the map of Europe after the ''Napoleonic Wars''.

=== Delegations ===
{| class="wikitable" style="width: 100%"
! Delegation !! Led by
|-
| [[Austrian Empire]] || Metternich
|-
| [[Kingdom of Prussia]] || Hardenberg
|}

* [[Austrian Empire]]
** [[Habsburg monarchy]]
*: the host
# the opening ball
# the [[Final Act]]
<!-- dates follow the Gregorian calendar -->
See [https://example.org/vienna the archive] &amp; [[Category:1815]]. <br/>
"""

suite =
  "test/fixtures/mwparserfromhell/conformance.json"
  |> File.read!()
  |> JSON.decode!()
  |> Map.fetch!("cases")
  |> Enum.map(& &1["input"])

pages =
  case System.argv() do
    [directory] ->
      texts =
        "#{directory}/*.wikitext"
        |> Path.wildcard()
        |> Enum.map(&File.read!/1)

      %{"pages" => texts}

    [] ->
      %{}
  end

inputs =
  Map.merge(pages, %{
    "an article" => [String.duplicate(section, 40)],
    "the suite's inputs" => suite,
    "stray closing tags" => [String.duplicate("a</br>b ", 8_000)]
  })

Benchee.run(
  %{
    "parse" => fn texts -> Enum.each(texts, &WikitextEx.parse!/1) end,
    "write back" =>
      {fn trees -> Enum.each(trees, &WikitextEx.to_wikitext/1) end,
       before_scenario: fn texts -> Enum.map(texts, &WikitextEx.parse!/1) end}
  },
  inputs: inputs,
  memory_time: 1
)
