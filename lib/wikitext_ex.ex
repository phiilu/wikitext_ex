defmodule WikitextEx do
  @moduledoc """
  WikitextEx - A robust MediaWiki wikitext parser for Elixir.

  WikitextEx provides functionality to parse MediaWiki wikitext markup into
  structured AST nodes, making it easy to process and analyze wiki content.

  ## Quick Start

      iex> # Parse wikitext into AST
      iex> {:ok, ast, _, _, _, _} = WikitextEx.parse("'''Bold''' and ''italic'' text")
      iex> # Work with the parsed AST
      iex> templates = WikitextEx.find_templates(ast)
      iex> length(templates)
      0
      iex> text_content = WikitextEx.extract_text(ast)
      iex> text_content
      "Bold and italic text"

  ## Main Functions

  - `parse/1` - Parse wikitext string into AST
  - `find_templates/1` - Extract all template nodes from AST
  - `find_links/1` - Extract all link nodes from AST
  - `extract_text/1` - Get plain text content from AST
  """

  alias WikitextEx.{Parser, AST}

  @doc """
  Parse wikitext markup into an AST.

  Returns the same tuple format as NimbleParsec for consistency:
  `{:ok, ast, rest, context, position, byte_offset}` on success or
  `{:error, reason, rest, context, position, byte_offset}` on failure.

  ## Examples

      iex> {:ok, ast, _, _, _, _} = WikitextEx.parse("'''Bold text'''")
      iex> [%WikitextEx.AST{type: :bold, value: nil, children: [%WikitextEx.AST{type: :text, value: %WikitextEx.AST.Text{content: "Bold text"}, children: []}]}] = ast
      [%WikitextEx.AST{type: :bold, value: nil, children: [%WikitextEx.AST{type: :text, value: %WikitextEx.AST.Text{content: "Bold text"}, children: []}]}]

      iex> {:ok, ast, _, _, _, _} = WikitextEx.parse("{{template|arg}}")
      iex> [%WikitextEx.AST{type: :template, value: %WikitextEx.AST.Template{name: "template", args: [positional: "arg"]}, children: []}] = ast
      [%WikitextEx.AST{type: :template, value: %WikitextEx.AST.Template{name: "template", args: [positional: "arg"]}, children: []}]

  """
  @spec parse(String.t()) ::
          {:ok, [AST.t()], String.t(), map(), {non_neg_integer(), non_neg_integer()},
           non_neg_integer()}
          | {:error, String.t(), String.t(), map(), {non_neg_integer(), non_neg_integer()},
             non_neg_integer()}
  def parse(wikitext) when is_binary(wikitext) do
    Parser.parse(wikitext)
  end

  @doc """
  Find all template nodes in an AST.

  ## Examples

      iex> {:ok, ast, _, _, _, _} = WikitextEx.parse("{{template1}} and {{template2|arg}}")
      iex> templates = WikitextEx.find_templates(ast)
      iex> length(templates)
      2

  """
  @spec find_templates([AST.t()]) :: [AST.t()]
  def find_templates(ast_nodes) when is_list(ast_nodes) do
    Enum.flat_map(ast_nodes, &do_find_templates/1)
  end

  defp do_find_templates(%AST{type: :template} = node), do: [node]
  defp do_find_templates(%AST{children: children}), do: find_templates(children)
  defp do_find_templates(_), do: []

  @doc """
  Find all link nodes in an AST (including categories and files).

  ## Examples

      iex> {:ok, ast, _, _, _, _} = WikitextEx.parse("[[Article]] [[Category:Example]]")
      iex> links = WikitextEx.find_links(ast)
      iex> length(links)
      2

  """
  @spec find_links([AST.t()]) :: [AST.t()]
  def find_links(ast_nodes) when is_list(ast_nodes) do
    Enum.flat_map(ast_nodes, &do_find_links/1)
  end

  defp do_find_links(%AST{type: type} = node)
       when type in [:link, :category, :file, :interlang_link] do
    [node]
  end

  defp do_find_links(%AST{children: children}), do: find_links(children)
  defp do_find_links(_), do: []

  @doc """
  Extract plain text content from AST nodes.

  This function recursively traverses the AST and extracts all text content,
  ignoring markup and structure.

  ## Examples

      iex> {:ok, ast, _, _, _, _} = WikitextEx.parse("'''Bold''' and ''italic'' text")
      iex> WikitextEx.extract_text(ast)
      "Bold and italic text"

  """
  @spec extract_text([AST.t()]) :: String.t()
  def extract_text(ast_nodes) when is_list(ast_nodes) do
    ast_nodes
    |> Enum.map(&do_extract_text/1)
    |> Enum.join("")
    |> String.trim()
  end

  defp do_extract_text(%AST{type: :text, value: %AST.Text{content: content}}) do
    content
  end

  defp do_extract_text(%AST{children: children}) do
    extract_text(children)
  end

  defp do_extract_text(_), do: ""

  @doc """
  Find all header nodes in an AST.

  ## Examples

      iex> {:ok, ast, _, _, _, _} = WikitextEx.parse("== Header ==\\nContent")
      iex> headers = WikitextEx.find_headers(ast)
      iex> length(headers)
      1

  """
  @spec find_headers([AST.t()]) :: [AST.t()]
  def find_headers(ast_nodes) when is_list(ast_nodes) do
    Enum.flat_map(ast_nodes, &do_find_headers/1)
  end

  defp do_find_headers(%AST{type: :header} = node), do: [node]
  defp do_find_headers(%AST{children: children}), do: find_headers(children)
  defp do_find_headers(_), do: []
end
