# AGENTS.md

WikitextEx parses MediaWiki wikitext into a lossless tree of `{type, meta, children}` tuples (text is a binary) and writes it back with `WikitextEx.to_wikitext/1`. It is an independent, generic library: keep code, comments, config and examples free of any one wiki's or project's names and conventions.

This file wins where a vendored skill (`skills-lock.json`) says otherwise.

## Pipeline

`WikitextEx.parse/2` runs `Tokenizer` (text → tokens), then `Builder` (tokens → nodes). `Writer` inverts `Builder`. `WikitextEx.AST` documents every node and its meta: it is the single source of truth for the tree's shape, so update its table when a node changes.

## Tokenizer

- **Backtracking.** Wikitext has no syntax errors: a construct that doesn't hold up fails, and its caller reads the opening as text. `Tokenizer.State` owns this: `State.fail/1` and `State.reject/1` throw, `State.attempt/2` catches, and failed routes (`{pos, context}`) are memoized so unterminated markup isn't re-read. Throws stay inside `State`.
- **Position contract.** Every markup function returns the state positioned at the next character to read.
- **Contexts** are bit flags per frame, saying what a character means where it is (`|` in a template vs. a table).

## Conformance

The behaviour reference is mwparserfromhell 0.7.2's **C tokenizer**, its default. Where it disagrees with mwparserfromhell's Python tokenizer, the C one wins (e.g. `"` is allowed in tag names; a closing tag's name may hold `<`). Settle a behaviour question by running the reference on the input, never by reading either tokenizer's source alone.

- `test/conformance_test.exs` compares trees against `test/fixtures/mwparserfromhell/conformance.json` (573 cases) and `test/fixtures/edge_cases.json`, and checks every input round-trips.
- A behaviour difference you find becomes a regression case: add a `.wikitext` file to `test/fixtures/edge_cases/`, regenerate `edge_cases.json`, and see it go red before fixing.
- Regenerate references with mwparserfromhell installed: `python -I scripts/mwph_reference.py files <dir> <out.json>` (or `mwtest <dir> <out.json>` for its test suite). `MWPH_TOKENIZER=python` selects the Python tokenizer, for comparison only.
- `test/corpus_test.exs` (tag `:corpus`, excluded by default) runs any reference: `WIKITEXT_CORPUS_REFERENCE=out.json mix test --only corpus`. Use it for real pages and fuzz batches after any tokenizer change.

## The rules tooling cannot check

Credo strict, Quokka and Dialyzer already hold layout, doc and spec coverage, pipes and naming shape. Check every function you write against the rest:

- **Single level of abstraction.** A function reads as a paragraph of same-altitude named steps. A byte match or `binary_part/3` beside steps like `read_template` is the tell: extract it down a level.
- **One thing per function.** A name needing "and" means split, not rename. A once-called helper that names no meaningful step is noise.
- **Names come from the domain**: MediaWiki's vocabulary (template, parameter, argument, link, tag, entity, heading) and the node types of `WikitextEx.AST`. A function is named for what it returns or does in wikitext terms; a generic verb (`run`, `process`, `handle`) only where it is exactly what happens.
- **Comments carry what code cannot**: a wikitext rule, in wikitext terms and naming no other parser, an invariant, or a "why not X". Delete one that restates the code. API docs say what the name and spec cannot: the contract, an invariant, a reason.
- **Docs describe the code as it stands**, in the present tense. "Now", "no longer" and "previously" are the tells; history is git's.
- **The standard library first.** What `Enum`, `Map`, `String` or `:binary` offers is never written by hand.
- **Repair what you touch.** `rg` every name, fact and path you change across code, tests, docs and the README, and fix each hit in the same change.

## Toolchain

`mise.toml` pins Elixir and OTP, and an agent shell isn't mise-activated: a bare `mix` resolves to another global install and recompiles `_build` for it. Run project commands as `mise exec -- mix …`; a bare `mix` in this file runs that way too.

## Checks

`mix format-lint` (Quokka formatting, warnings as errors, `credo --strict`) and `mix test` before committing; lefthook's hooks and `.github/workflows/ci.yml` run the rest (Dialyzer, audits, Elixir 1.18). Thread state through pipelines and helper functions rather than rebinding a variable. A rule tooling can check becomes a Credo check in `credo_checks/`, tested in `test/wikitext_ex/checks/`.

Commits are Conventional Commits. release-please derives the version (`mix.exs`, the README's install snippet) and `CHANGELOG.md` from them on `main`, so leave both to its release PR; a breaking change's `BREAKING CHANGE:` footer is its release note.

## Done

A change is done when it is proven and reviewed.

- **Proven.** The tests ran on the final code, plus the corpus and fuzz references for a tokenizer change, and the report says what ran.
- **Reviewed.** Before committing, `code-review` with `main` as the fixed point, uncommitted work included. A change to docs, skills or CI config alone needs only your own read of the diff.

## Agent skills

### Issue tracker

GitHub Issues and pull requests on `phiilu/wikitext_ex`, through `gh`.

### Domain docs

No `GLOSSARY.md`: the domain language is MediaWiki's wikitext vocabulary and the node table in `WikitextEx.AST`.

## Gotchas

- `NUL` is ordinary text here. (mwparserfromhell's C tokenizer stops at it.)
- Whitespace means Python's `str.isspace` set (`WikitextEx.Text`), since names and paddings are split on it to match the reference.
- `test/support/reference.ex` normalises both sides before comparison: adjacent text is merged, and `:list_item` nodes are flattened back into per-marker entries.
