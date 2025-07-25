# WikitextEx

[![Hex.pm](https://img.shields.io/hexpm/v/wikitext_ex.svg)](https://hex.pm/packages/wikitext_ex)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/wikitext_ex)

A MediaWiki wikitext parser for Elixir that converts wikitext markup into structured AST nodes. WikitextEx supports templates, links, formatting, tables, and other wikitext elements commonly found in MediaWiki content.

> **⚠️ Current Status: Beta** - WikitextEx successfully parses many common wikitext patterns but has known limitations with certain edge cases. See [Known Limitations](#known-limitations) for details.

## Features

- **Complete Wikitext Support**: Parse headers, links, templates, formatting (bold/italic), lists, tables, and more
- **Structured AST**: Clean, typed AST nodes for easy manipulation and analysis
- **Template Parsing**: Full support for MediaWiki template syntax with named and positional arguments
- **HTML Tag Support**: Parse HTML tags, comments, and special tags like `<ref>` and `<nowiki>`
- **Table Parsing**: Complete MediaWiki table syntax support with headers and data cells
- **Robust Formatting**: Handles complex bold/italic combinations and nested formatting
- **Link Types**: Support for internal links, categories, files, and interlanguage links

## Installation

Add `wikitext_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:wikitext_ex, "~> 0.1.0"}
  ]
end
```

## Usage

### Basic Parsing

```elixir
# Parse simple wikitext
{:ok, ast, _, _, _, _} = WikitextEx.Parser.parse("'''Bold text''' and ''italic text''")

# The result is a list of AST nodes
[
  %WikitextEx.AST{type: :bold, children: [%WikitextEx.AST{type: :text, value: %WikitextEx.AST.Text{content: "Bold text"}}]},
  %WikitextEx.AST{type: :text, value: %WikitextEx.AST.Text{content: " and "}},
  %WikitextEx.AST{type: :italic, children: [%WikitextEx.AST{type: :text, value: %WikitextEx.AST.Text{content: "italic text"}}]}
]
```

### Templates

```elixir
# Parse templates with arguments
{:ok, ast, _, _, _, _} = WikitextEx.Parser.parse("{{template|arg1|key=value}}")

# Results in template AST node
%WikitextEx.AST{
  type: :template,
  value: %WikitextEx.AST.Template{
    name: "template",
    args: [
      {:positional, "arg1"},
      {:named, %{"key" => "value"}}
    ]
  }
}
```

### Links and Categories

```elixir
# Parse various link types
{:ok, ast, _, _, _, _} = WikitextEx.Parser.parse("[[Article]] [[Category:Example]] [[File:image.jpg|thumb]]")

# Results in different AST node types:
# - :link for regular internal links
# - :category for category links
# - :file for file/media links
```

### Headers

```elixir
# Parse headers
{:ok, ast, _, _, _, _} = WikitextEx.Parser.parse("== Section Header ==")

%WikitextEx.AST{
  type: :header,
  value: %WikitextEx.AST.Header{level: 2},
  children: [%WikitextEx.AST{type: :text, value: %WikitextEx.AST.Text{content: "Section Header"}}]
}
```

### Tables

```elixir
wikitext = """
{|
! Header 1 !! Header 2
|-
| Cell 1 || Cell 2
|}
"""

{:ok, ast, _, _, _, _} = WikitextEx.Parser.parse(wikitext)
# Results in table AST with rows and cells
```

## AST Structure

WikitextEx produces a structured AST where each node follows this pattern:

```elixir
%WikitextEx.AST{
  type: atom(),           # The type of element (:text, :template, :link, etc.)
  value: struct() | nil,  # Type-specific data (e.g., %AST.Text{content: "..."})
  children: [%AST{}]      # Nested AST nodes
}
```

### Supported AST Node Types

- `:text` - Plain text content
- `:header` - Headers (=, ==, ===, etc.)
- `:template` - Template invocations ({{template|args}})
- `:link` - Internal wiki links ([[Page]])
- `:category` - Category links ([[Category:Name]])
- `:file` - File/media links ([[File:image.jpg]])
- `:interlang_link` - Interlanguage links ([[de:Page]])
- `:bold` - Bold formatting ('''text''')
- `:italic` - Italic formatting (''text'')
- `:list_item` - List items (\* or #)
- `:table` - Tables ({| ... |})
- `:table_row` - Table rows
- `:table_cell` - Table cells (header or data)
- `:html_tag` - HTML tags (<span>, <div>, etc.)
- `:ref` - Reference tags (<ref>)
- `:comment` - HTML comments (<!-- -->)
- `:nowiki` - Nowiki sections (<nowiki>)

## Advanced Usage

### Working with AST

```elixir
# Extract text content from headers or other containers
WikitextEx.AST.text_content(ast_node.children)

# Navigate the AST tree
defmodule WikitextWalker do
  def find_templates(ast_nodes) do
    Enum.flat_map(ast_nodes, fn
      %WikitextEx.AST{type: :template} = node -> [node]
      %WikitextEx.AST{children: children} -> find_templates(children)
      _ -> []
    end)
  end
end
```

### Custom Processing

```elixir
defmodule WikitextProcessor do
  def extract_links(wikitext) do
    case WikitextEx.Parser.parse(wikitext) do
      {:ok, ast, _, _, _, _} ->
        ast
        |> find_links()
        |> Enum.map(& &1.value.target)

      {:error, _} ->
        []
    end
  end

  defp find_links(ast_nodes) do
    Enum.flat_map(ast_nodes, fn
      %WikitextEx.AST{type: :link} = node -> [node]
      %WikitextEx.AST{children: children} -> find_links(children)
      _ -> []
    end)
  end
end
```

## Development

```bash
# Clone the repository
git clone https://github.com/your-username/wikitext_ex.git
cd wikitext_ex

# Install dependencies
mix deps.get

# Run tests
mix test

# Generate documentation
mix docs
```

## Known Limitations

WikitextEx works well for typical wiki content, but has some known limitations:

### Parser Edge Cases

- **Complex whitespace handling**: Some complex whitespace patterns may not parse correctly
- **Deeply nested structures**: Very deeply nested content may cause parsing issues
- **Advanced MediaWiki syntax**: Some advanced or rarely-used MediaWiki features are not yet supported
- **Large content blocks**: Performance may degrade with extremely large wikitext files

### Parsing Behavior

- The parser may return partial results with unparsed content in the `rest` field for complex edge cases
- Most common wikitext patterns parse successfully

### Recommendations

- **Test with your content**: Always test WikitextEx with your specific wikitext before production use
- **Handle partial parsing**: Check the `rest` field in parse results for unparsed content
- **Report issues**: Please report parsing failures with examples to help improve the parser

## Testing

WikitextEx includes a comprehensive test suite with 58 tests covering various wikitext patterns and edge cases. Run the tests with:

```bash
mix test
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Write tests for your changes
4. Ensure all tests pass (`mix test`)
5. Commit your changes (`git commit -am 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](https://github.com/phiilu/wikitext_ex/blob/main/LICENSE) file for details.

## Acknowledgments

- Built with [NimbleParsec](https://github.com/dashbitco/nimble_parsec) for robust parsing
- Inspired by MediaWiki's wikitext specification
- Designed for use with Wikipedia and other MediaWiki-based wikis

