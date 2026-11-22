# WikitextEx

[![Hex.pm](https://img.shields.io/hexpm/v/wikitext_ex.svg)](https://hex.pm/packages/wikitext_ex)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/wikitext_ex)
[![CI](https://img.shields.io/github/actions/workflow/status/phiilu/wikitext_ex/ci.yml?branch=main&label=CI)](https://github.com/phiilu/wikitext_ex/actions/workflows/ci.yml?query=branch%3Amain)
[![License](https://img.shields.io/hexpm/l/wikitext_ex.svg)](https://github.com/phiilu/wikitext_ex/blob/main/LICENSE)

A MediaWiki wikitext parser in pure Elixir. It turns wikitext into a tree of
plain tuples, and writes a tree back to wikitext exactly as it was.

- **Every input parses.** Wikitext has no syntax errors: markup that doesn't
  complete a construct, like an unclosed `{{` or a `[[` across a line break, is
  text, as it is on the wiki.
- **Lossless.** `WikitextEx.to_wikitext/1` gives back the input byte for byte,
  so you can change a tree and save it without disturbing the rest of the page.
- **Tuples, not structs.** Nodes are `{type, meta, children}`, the shape of
  Elixir's own AST, so they pattern-match and walk like it.
- **Source-level.** Templates stay templates: the parser reads what the page
  says, it doesn't render it the way MediaWiki would.

## Installation

<!-- x-release-please-start-version -->
```elixir
def deps do
  [
    {:wikitext_ex, "~> 0.2.0"}
  ]
end
```
<!-- x-release-please-end -->

## Usage

```elixir
iex> WikitextEx.parse!("== Fauna ==\n{{Speciesbox|name={{lang|de|Steinbock}}}}\n* [[Alpine ibex]]")
[
  {:heading, %{level: 2}, [" Fauna "]},
  "\n",
  {:template, %{name: "Speciesbox", name_padding: {"", ""}},
   [
     {:param, %{name: "name", named: true, name_padding: {"", ""}},
      [
        {:template, %{name: "lang", name_padding: {"", ""}},
         [
           {:param, %{name: "1", named: false, name_padding: {"", ""}}, ["de"]},
           {:param, %{name: "2", named: false, name_padding: {"", ""}}, ["Steinbock"]}
         ]}
      ]}
   ]},
  "\n",
  {:list_item, %{marker: "*"},
   [" ", {:link, %{target: "Alpine ibex", target_padding: {"", ""}, pipe: false}, []}]}
]
```

`WikitextEx.parse/2` returns `{:ok, nodes}`, or `{:error, :invalid_utf8}` for
input that isn't UTF-8; `WikitextEx.parse!/2` raises instead.

### Walking the tree

`WikitextEx.AST` has `prewalk`, `postwalk`, `traverse` and `filter` over a
tree, and `text/1` and `attributes/1` for the most common questions:

```elixir
nodes = WikitextEx.parse!("{{Speciesbox|name={{lang|de|Gämse}}}} ''[[Rupicapra rupicapra|Chamois]]'' &amp; more")

WikitextEx.AST.filter(nodes, &match?({:template, _, _}, &1))
|> Enum.map(fn {:template, meta, _params} -> meta.name end)
#=> ["Speciesbox", "lang"]

WikitextEx.AST.text(nodes)
#=> " Chamois & more"
```

`Macro.prewalk/3` and the like work on the tree as well.

### Changing a page

Rewrite the nodes you care about and write the tree back. Everything else comes
out as it went in:

```elixir
"Servus ''Großglockner'' <!-- keep me -->"
|> WikitextEx.parse!()
|> WikitextEx.AST.prewalk(fn
  {:italic, _meta, children} -> {:bold, %{}, children}
  node -> node
end)
|> WikitextEx.to_wikitext()
#=> "Servus '''Großglockner''' <!-- keep me -->"
```

## Nodes

Text is a binary; every other node is `{type, meta, children}`:

| Wikitext | Type | Children |
| --- | --- | --- |
| `{{name\|a\|key=b}}` | `:template` | its `:param`s |
| `{{{name\|default}}}` | `:argument` | the default |
| `[[target\|text]]` | `:link` | the text |
| `[url title]`, a bare URL | `:external_link` | the title |
| `== title ==` | `:heading` | the title |
| `''…''`, `'''…'''` | `:italic`, `:bold` | the contents |
| `*`, `#`, `;`, `:` | `:list_item` | the rest of the line |
| `----` | `:hr` | — |
| `{\| … \|}`, `\|-`, `\|`, `!` | `:table`, `:table_row`, `:table_cell` | rows and cells |
| `<tag>…</tag>` | `:html_tag` | the contents |
| `&amp;`, `&#38;` | `:entity` | — |
| `<!-- … -->` | `:comment` | — |

The meta of each node is documented in `WikitextEx.AST`. Links are not split
into categories, files and interlanguage links: whether `[[Category:X]]` is a
category depends on the wiki's namespaces, so it's a `:link` whose target you
can check.

## Correctness

The parser follows the grammar and the tokenizer design of
[mwparserfromhell](https://github.com/earwig/mwparserfromhell), the reference
source-level wikitext parser. The test suite checks the trees of its 573 test
inputs against its output, plus every input written back. Differential fuzzing
against it, over tens of thousands of generated inputs, finds no differences.

## Development

[mise](https://mise.jdx.dev) installs the toolchain CI uses: Elixir, OTP,
Python and uv for the reference trees, and the git hooks' tools.

```bash
git clone https://github.com/phiilu/wikitext_ex && cd wikitext_ex
mise trust            # allow the repository's mise.toml
mise run setup        # toolchain, dependencies, git hooks, a build and the PLTs
```

Then:

```bash
mix format-lint       # format, compile without warnings, credo --strict
mix test
mix dialyzer
mix bench             # Benchee; `mix bench path/to/pages` adds your own pages
mise tasks            # the reference, corpus and fuzz tasks
```

The reference trees come from mwparserfromhell, at the version
`scripts/mwph_reference.py` pins, and CI regenerates them on every change.

## License

MIT; see [LICENSE](https://github.com/phiilu/wikitext_ex/blob/main/LICENSE). The test inputs in `test/fixtures/mwparserfromhell`
come from mwparserfromhell's test suite, under its MIT license in that directory.
