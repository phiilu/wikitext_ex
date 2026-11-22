# Benchmarks parsing and writing back. `mix bench path/to/pages` adds a
# directory of `.wikitext` files as one more input.

section = """
== Hohe Tauern National Park ==
{{Infobox protected area|name=Hohe Tauern National Park|location=[[Austria]]}}
The '''Hohe Tauern National Park''' is the largest nature reserve in the Alps, \
around [[Großglockner|Austria's highest mountain]].<ref name="park">{{Citation|title=Hohe Tauern National Park|publisher=Nationalpark Hohe Tauern}}</ref> \
Its ''Alpine marmots'' whistle to warn each other.

=== Animals ===
{| class="wikitable" style="width: 100%"
! Animal !! German name
|-
| [[Alpine ibex]] || Steinbock
|-
| [[Chamois]] || Gämse
|}

* [[Alpine marmot]]
** [[Marmota]]
*: a rodent
# the bearded vulture
# the [[golden eagle]]
<!-- the park spans Carinthia, Salzburg and Tyrol -->
See [https://example.org/hohe-tauern the park] &amp; [[Category:Fauna of Austria]]. <br/>
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
