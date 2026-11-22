# CLAUDE.md

WikitextEx parses MediaWiki wikitext into a lossless tree of `{type, meta, children}` tuples (text is a binary) and writes it back with `WikitextEx.to_wikitext/1`. It is an independent, generic library: keep code, comments, config and examples free of any one wiki's or project's names and conventions.

## Pipeline

`WikitextEx.parse/2` runs `Tokenizer` (text → tokens), then `Builder` (tokens → nodes). `Writer` inverts `Builder`. `WikitextEx.AST` documents every node and its meta: it is the single source of truth for the tree's shape, so update its table when a node changes.

## Tokenizer

- **Backtracking.** Wikitext has no syntax errors: a construct that doesn't hold up fails, and its caller reads the opening as text. `Tokenizer.State` owns this: `State.fail/1` and `State.reject/1` throw, `State.attempt/2` catches, and failed routes (`{pos, context}`) are memoized so unterminated markup isn't re-read. Throws stay inside `State`.
- **Position contract.** Every markup function returns the state positioned at the next character to read.
- **Contexts** are bit flags per frame, saying what a character means where it is (`|` in a template vs. a table).
- Comments in `lib/` describe wikitext rules in wikitext terms. Write idiomatic Elixir, and name no other parser in `lib/`.

## Conformance

The behaviour reference is mwparserfromhell 0.7.2's **C tokenizer**, its default. Where it disagrees with mwparserfromhell's Python tokenizer, the C one wins (e.g. `"` is allowed in tag names; a closing tag's name may hold `<`).

- `test/conformance_test.exs` compares trees against `test/fixtures/mwparserfromhell/conformance.json` (573 cases) and `test/fixtures/edge_cases.json`, and checks every input round-trips.
- A behaviour difference you find becomes a regression case: add a `.wikitext` file to `test/fixtures/edge_cases/`, regenerate `edge_cases.json`, and see it go red before fixing.
- Regenerate references with mwparserfromhell installed: `python -I scripts/mwph_reference.py files <dir> <out.json>` (or `mwtest <dir> <out.json>` for its test suite). `MWPH_TOKENIZER=python` selects the Python tokenizer, for comparison only.
- `test/corpus_test.exs` (tag `:corpus`, excluded by default) runs any reference: `WIKITEXT_CORPUS_REFERENCE=out.json mix test --only corpus`. Use it for real pages and fuzz batches after any tokenizer change.

## Checks

`mix format-lint` (Quokka formatting, warnings as errors, `credo --strict`) and `mix test` before committing; lefthook's hooks and `.github/workflows/ci.yml` run the rest (Dialyzer, audits, Elixir 1.18). Credo's strict config flags rebinding a variable in a function body and bare `_` for unused names: thread state through pipelines and helper functions, and name unused variables (`_rest`).

Commits are Conventional Commits. release-please derives the version (`mix.exs`, the README's install snippet) and `CHANGELOG.md` from them on `main`, so leave both to its release PR; a breaking change's `BREAKING CHANGE:` footer is its release note.

## Gotchas

- `NUL` is ordinary text here. (mwparserfromhell's C tokenizer stops at it.)
- Whitespace means Python's `str.isspace` set (`WikitextEx.Text`), since names and paddings are split on it to match the reference.
- `test/support/reference.ex` normalises both sides before comparison: adjacent text is merged, and `:list_item` nodes are flattened back into per-marker entries.
