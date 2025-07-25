# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2025-07-25

### Added
- Comprehensive doctests for all modules (11 doctests total)
- New test file `test/doctest_test.exs` to run doctests for all modules
- Doctests for `WikitextEx.AST.text_content/1` function
- Executable doctests converted from Quick Start examples

### Fixed
- Broken doctests in `WikitextEx.parse/1` with correct AST structure
- Doctests in `WikitextEx.Parser` module
- Documentation examples now properly executable as tests

### Changed
- Enhanced documentation with working code examples
- All 11 doctests now pass alongside existing 58 tests

## [0.1.0] - 2025-01-25

### Added
- Initial release of WikitextEx
- Complete MediaWiki wikitext parser using NimbleParsec
- Support for headers, templates, links, formatting, lists, and tables
- Structured AST with typed nodes for all wikitext elements
- Template parsing with named and positional arguments
- Link type differentiation (internal, category, file, interlanguage)
- HTML tag support including `<ref>`, `<nowiki>`, and comments
- Comprehensive test suite with 58 tests
- Complete documentation with usage examples
- Production-ready packaging for Hex.pm

### Parser Features
- Text formatting: bold (`'''`), italic (`''`), and combinations
- Headers with 1-6 levels (`=` to `======`)
- Internal links (`[[Page]]`) with display text support
- Categories (`[[Category:Name]]`) and file links (`[[File:image.jpg]]`)
- Templates (`{{template|args}}`) with full argument parsing
- Lists (ordered `#` and unordered `*`) with nesting support
- Tables (`{| ... |}`) with headers and data cells
- HTML tags with attribute parsing
- Reference tags (`<ref>`) with name and group support
- Nowiki sections (`<nowiki>`) for literal text
- HTML comments (`<!-- -->`)
- Interlanguage links (`[[de:Page]]`)

### API
- `WikitextEx.parse/1` - Main parsing function
- `WikitextEx.find_templates/1` - Extract template nodes
- `WikitextEx.find_links/1` - Extract link nodes  
- `WikitextEx.find_headers/1` - Extract header nodes
- `WikitextEx.extract_text/1` - Get plain text content
- `WikitextEx.AST.text_content/1` - Extract text from AST children

[Unreleased]: https://github.com/phiilu/wikitext_ex/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/phiilu/wikitext_ex/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/phiilu/wikitext_ex/releases/tag/v0.1.0