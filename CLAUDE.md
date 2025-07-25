# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WikitextEx is an Elixir library that parses MediaWiki wikitext markup into structured AST nodes. It's built using NimbleParsec for robust parsing and supports the complete range of wikitext syntax including templates, links, formatting, tables, and HTML tags.

## Development Commands

### Core Development
- `mix deps.get` - Install dependencies
- `mix compile` - Compile the project
- `mix test` - Run all tests (58 comprehensive test cases)
- `mix test test/parser_test.exs` - Run specific test file
- `mix test test/parser_test.exs:42` - Run specific test by line number
- `mix format` - Format code according to .formatter.exs
- `mix docs` - Generate documentation with ExDoc

### Interactive Development
- `iex -S mix` - Start interactive Elixir session with project loaded
- `mix run` - Run the application (default Mix task)

### Quality Assurance
- `mix deps.audit` - Check for known vulnerabilities in dependencies
- `mix xref` - Cross-reference analysis for unused functions

## Code Architecture

### Core Components

**Parser (`lib/parser.ex`)**
- Built with NimbleParsec combinators for robust grammar handling
- Defines complex parsing rules for all MediaWiki wikitext elements
- Uses recursive descent parsing with proper precedence handling
- Contains reduction functions to transform parse results into AST nodes

**AST (`lib/ast.ex`)**
- Defines the complete AST node structure and all node types
- Each node has `type`, `value`, and `children` fields
- Includes specialized structs for each element type (Template, Link, Header, etc.)
- Provides utility functions like `text_content/1` for extracting plain text

**Main Module (`lib/wikitext_ex.ex`)**
- Public API with convenience functions
- `parse/1` - Main parsing entry point
- Helper functions: `find_templates/1`, `find_links/1`, `extract_text/1`, `find_headers/1`

### Parsing Strategy

The parser uses a layered approach:

1. **Text Parsing**: Greedy text consumption with character exclusion sets to avoid conflicts
2. **Precedence Handling**: Bold/italic combinations parsed in specific order (5-apostrophe, 3-apostrophe, 2-apostrophe)
3. **Context-Aware Parsing**: Different parsing rules for different contexts (template values, list content, etc.)
4. **Recursive Structure**: Container elements can contain other wikitext elements

### Key Parsing Patterns

- **Templates**: `{{name|arg1|key=value}}` with nested template support
- **Links**: `[[target|display]]` with category, file, and interlang variants
- **Formatting**: Bold (`'''`), italic (`''`), and combinations (`'''''`)
- **Tables**: Full MediaWiki table syntax with headers and data cells
- **HTML**: Both self-closing and container tags with attribute parsing

### AST Node Types

The parser produces these main node types:
- `:text` - Plain text content
- `:template` - Template invocations with arguments
- `:link`, `:category`, `:file`, `:interlang_link` - Various link types
- `:header` - Section headers with levels 1-6
- `:bold`, `:italic` - Text formatting
- `:list_item` - Ordered/unordered list items with nesting
- `:table`, `:table_row`, `:table_cell` - Table structure
- `:html_tag`, `:comment`, `:ref`, `:nowiki` - HTML elements

### Test Architecture

Tests are organized by functionality:
- `parser_test.exs` - Core parsing functionality and edge cases
- `parser_table_test.exs` - Specific table parsing tests
- `wikitext_fixture.ex` - Helper for loading test fixtures from files
- Test fixtures stored in `test/support/fixtures/wikitext/` directory

### Dependencies

- **NimbleParsec** (~> 1.4) - Core parsing engine
- **ExDoc** (~> 0.31) - Documentation generation (dev only)

## Development Patterns

### Adding New Wikitext Elements

1. Define the AST struct in `ast.ex`
2. Create parsing rules in `parser.ex` using NimbleParsec combinators
3. Add reduction function to transform parse results to AST
4. Add the parser to the main `element` choice combinator
5. Write comprehensive tests covering edge cases

### Parser Development Guidelines

- Use character exclusion sets (`@basic_exclusions`, etc.) to avoid conflicts
- Handle nested structures with recursive parsers
- Always include reduction functions to create proper AST nodes
- Test both successful parsing and edge cases
- Consider precedence when adding new elements to choice combinators

### Working with Templates

Templates support both positional and named arguments. The parser handles:
- Nested templates within arguments
- Complex argument values with formatting
- Empty/whitespace argument filtering
- Proper argument type classification (`:positional` vs `:named`)