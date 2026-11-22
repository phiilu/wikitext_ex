# AGENTS.md

WikitextEx parses MediaWiki wikitext into a lossless tree and writes it back. It is an independent, generic library: keep code, comments, config and examples free of any one wiki's or project's names and conventions.

This file points at where things are written down; the code, its docs and its config are the source of truth. It wins where a vendored skill (`skills-lock.json`) says otherwise.

## Where to read

- **The tree**: `WikitextEx.AST`'s moduledoc documents every node and its meta. A node change updates it.
- **The pipeline**: start at `WikitextEx.parse/2`.
- **The tokenizer**: the header comments of `WikitextEx.Tokenizer` and `WikitextEx.Tokenizer.State` explain backtracking, contexts and the position contract. Read both before changing either.
- **Conformance**: the behaviour reference is mwparserfromhell's C tokenizer. `ConformanceTest`'s moduledoc says how references are made and what a newly found difference becomes; `CorpusTest`'s how to check real pages and fuzz batches, which every tokenizer change runs. Settle a behaviour question by running the reference on the input, never by reading a tokenizer's source alone.
- **Checks and tasks**: the aliases in `mix.exs`, `mise tasks`, `lefthook.yml` and the CI workflows. A rule tooling can check becomes a Credo check, loaded through `.credo.exs`.
- **Releases**: release-please owns the version and the changelog (its config names the files). Commits are Conventional Commits; a breaking change's `BREAKING CHANGE:` footer is its release note.

## The rules tooling cannot check

Check every function you write against them:

- **Single level of abstraction.** A function reads as a paragraph of same-altitude named steps. A byte match or `binary_part/3` beside named steps is the tell: extract it down a level.
- **One thing per function.** A name needing "and" means split, not rename. A once-called helper that names no meaningful step is noise.
- **Names come from the domain**: MediaWiki's vocabulary (template, parameter, argument, link, tag, entity, heading) and the node types of `WikitextEx.AST`. A generic verb (`run`, `process`, `handle`) only where it is exactly what happens.
- **Comments carry what code cannot**: a wikitext rule, in wikitext terms and naming no other parser, an invariant, or a "why not X". Delete one that restates the code. API docs say what the name and spec cannot: the contract, an invariant, a reason.
- **Docs describe the code as it stands**, in the present tense. "Now", "no longer" and "previously" are the tells; history is git's.
- **The standard library first.** What `Enum`, `Map`, `String` or `:binary` offers is never written by hand. Whitespace is the exception: it is `WikitextEx.Text`'s, which its header explains.
- **Repair what you touch.** `rg` every name, fact and path you change across code, tests, docs and the README, and fix each hit in the same change.

## Toolchain

`mise.toml` pins the toolchain, and an agent shell isn't mise-activated: a bare `mix` resolves to another global install and recompiles `_build` for it. Run project commands as `mise exec -- mix …`.

## Done

A change is done when it is proven and reviewed.

- **Proven.** What shows it works ran on the final code, and the report says what ran.
- **Reviewed.** Before committing, `code-review` with `main` as the fixed point, uncommitted work included. A change to docs, skills or CI config alone needs only your own read of the diff.

## Agent skills

### Issue tracker

GitHub Issues and pull requests of this repository, through `gh`.

### Domain docs

No glossary: the domain language is MediaWiki's wikitext vocabulary and the node types of `WikitextEx.AST`.
