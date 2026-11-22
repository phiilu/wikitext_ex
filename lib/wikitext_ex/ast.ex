defmodule WikitextEx.AST do
  @moduledoc """
  The nodes `WikitextEx.parse/2` produces, and functions to walk them.

  Text is a binary. Every other node is a `{type, meta, children}` tuple, with
  `meta` a map and `children` a list of nodes. This is the shape of Elixir's
  own AST, so `Macro.prewalk/3` and friends walk a tree too; the walks here do
  the same with a contract of their own.

  The parts of a node that are wikitext are its children, so a walk reaches
  everything: a template's parameters, and the templates inside them. The meta
  holds the rest, including what is needed to write the node back out exactly
  (`WikitextEx.to_wikitext/1`): the whitespace around a name, the quotes of an
  attribute. Values that are wikitext but kept in the meta, such as a
  template's name or an attribute's value, are their source text.

  ## Nodes

  | Wikitext | Node |
  | --- | --- |
  | text | `"text"` |
  | `{{name\\|a\\|key=b}}` | `{:template, %{name: "name", name_padding: {lead, trail}}, params}` |
  | a template parameter | `{:param, %{name: "1" \\| "key", name_padding: {lead, trail}, named: boolean}, value}` |
  | `{{{name\\|default}}}` | `{:argument, %{name: "name", name_padding: {lead, trail}, default: boolean}, default}` |
  | `[[target\\|text]]` | `{:link, %{target: "target", target_padding: {lead, trail}, pipe: boolean}, text}` |
  | `[url title]`, a bare URL | `{:external_link, %{url: url, brackets: boolean, separator: " " \\| "" \\| nil}, title}` |
  | `== title ==` | `{:heading, %{level: 1..6}, title}` |
  | `''text''` | `{:italic, %{}, children}` |
  | `'''text'''` | `{:bold, %{}, children}` |
  | `* item`, `#`, `;`, `:` | `{:list_item, %{marker: "*#"}, rest_of_line}` |
  | `----` | `{:hr, %{markup: "----"}, []}` |
  | `{\\| ... \\|}` | `{:table, %{attributes: attributes, padding: padding}, rows_and_cells}` |
  | `\\|-` | `{:table_row, %{attributes: attributes, padding: padding}, cells}` |
  | `\\|`, `\\|\\|`, `!`, `!!` | `{:table_cell, %{header: boolean, markup: markup, attributes: attributes, padding: padding, separator: "\\|" \\| nil}, contents}` |
  | `<tag attr="v">...</tag>` | `{:html_tag, %{tag: tag, attributes: attributes, padding: padding, self_closing: boolean, implicit: boolean, invalid: boolean, closing_tag: tag \\| nil}, contents}` |
  | `&amp;`, `&#38;` | `{:entity, %{source: "&amp;", char: "&"}, []}` |
  | `<!-- text -->` | `{:comment, %{content: " text "}, []}` |

  Children are as written, whitespace included: the title of `== History ==`
  is `[" History "]`. A template parameter written without a name is named by
  its position among those without one, from `"1"`; `named` tells it from one
  written as `1=`. A list item holds the rest of its line, up to its newline;
  a list nested two deep has the marker `"**"`.

  Attributes are maps with `:name` and `:value` (`nil` for an attribute
  without one), and `:quote`, `:pad_first`, `:pad_before_eq` and
  `:pad_after_eq` to write them back. `attributes/1` gives them as a map.

  A tag's or table markup's `padding` is the whitespace after its attributes:
  before an HTML tag's `>` or `/>`, before a table cell's separator, and after
  a table's or row's markup, its newline included. A void tag written without its
  slash, `<br>`, is `self_closing` and `implicit`; one written as a closing
  tag, `</br>`, is `invalid` too. `closing_tag` is the tag's name as its
  closing tag writes it, `nil` for a self-closing tag.

  Tags whose contents are not wikitext, such as `<nowiki>`, `<pre>` and
  `<math>`, hold their contents as text.
  """

  @typedoc "A node: text, or `{type, meta, children}`."
  @type t() :: String.t() | {atom(), map(), [t()]}

  @doc """
  Walks `nodes` depth-first, calling `fun` on each node before its children,
  and returns the nodes `fun` gives back.

      iex> "''[[Main Page]]''"
      ...> |> WikitextEx.parse!()
      ...> |> WikitextEx.AST.prewalk(fn
      ...>   {:italic, _meta, children} -> {:bold, %{}, children}
      ...>   node -> node
      ...> end)
      ...> |> WikitextEx.to_wikitext()
      "'''[[Main Page]]'''"

  """
  @spec prewalk([t()] | t(), (t() -> t())) :: [t()] | t()
  def prewalk(nodes, fun) do
    nodes
    |> prewalk(nil, fn node, nil -> {fun.(node), nil} end)
    |> elem(0)
  end

  @doc """
  Like `prewalk/2`, folding `acc` through `fun`, which returns
  `{node, acc}`.
  """
  @spec prewalk([t()] | t(), acc, (t(), acc -> {t(), acc})) :: {[t()] | t(), acc} when acc: term()
  def prewalk(nodes, acc, fun), do: traverse(nodes, acc, fun, &{&1, &2})

  @doc """
  Walks `nodes` depth-first, calling `fun` on each node after its children.
  """
  @spec postwalk([t()] | t(), (t() -> t())) :: [t()] | t()
  def postwalk(nodes, fun) do
    nodes
    |> postwalk(nil, fn node, nil -> {fun.(node), nil} end)
    |> elem(0)
  end

  @doc """
  Like `postwalk/2`, folding `acc` through `fun`, which returns
  `{node, acc}`.
  """
  @spec postwalk([t()] | t(), acc, (t(), acc -> {t(), acc})) :: {[t()] | t(), acc}
        when acc: term()
  def postwalk(nodes, acc, fun), do: traverse(nodes, acc, &{&1, &2}, fun)

  @doc """
  Walks `nodes` depth-first, calling `pre` on each node before its children
  and `post` after them, both folding `acc`.
  """
  @spec traverse([t()] | t(), acc, (t(), acc -> {t(), acc}), (t(), acc -> {t(), acc})) ::
          {[t()] | t(), acc}
        when acc: term()
  def traverse(nodes, acc, pre, post) when is_list(nodes),
    do: Enum.map_reduce(nodes, acc, &traverse(&1, &2, pre, post))

  def traverse(node, acc, pre, post) do
    case pre.(node, acc) do
      {{type, meta, children}, acc} ->
        {children, acc} = traverse(children, acc, pre, post)
        post.({type, meta, children}, acc)

      {node, acc} ->
        post.(node, acc)
    end
  end

  @doc """
  The nodes in `nodes`, at any depth, for which `fun` returns a truthy value,
  in document order.

      iex> "{{Speciesbox|name={{lang|de|Gämse}}}}"
      ...> |> WikitextEx.parse!()
      ...> |> WikitextEx.AST.filter(&match?({:template, _, _}, &1))
      ...> |> Enum.map(fn {:template, meta, _params} -> meta.name end)
      ["Speciesbox", "lang"]

  """
  @spec filter([t()] | t(), (t() -> as_boolean(term()))) :: [t()]
  def filter(nodes, fun) do
    {_nodes, found} =
      prewalk(nodes, [], fn node, found ->
        if fun.(node), do: {node, [node | found]}, else: {node, found}
      end)

    Enum.reverse(found)
  end

  @doc """
  The text of `nodes` as a reader sees it: the text of links and formatting,
  entities as their characters. Templates, arguments and comments have none;
  a link without text is its target, a bare URL itself.

      iex> "'''[[Rupicapra rupicapra|Chamois]]''' &amp; {{lang|de|Gämse}}"
      ...> |> WikitextEx.parse!()
      ...> |> WikitextEx.AST.text()
      "Chamois & "

  """
  @spec text([t()] | t()) :: String.t()
  def text(nodes) do
    nodes
    |> text_iodata()
    |> IO.iodata_to_binary()
  end

  @doc """
  The attributes of a tag, table, row or cell, by lowercase name. An
  attribute without a value has `""`; of two with the same name, the last
  wins, as in HTML.

      iex> [tag] = WikitextEx.parse!(~s(<span class="nowrap" hidden>1955</span>))
      iex> WikitextEx.AST.attributes(tag)
      %{"class" => "nowrap", "hidden" => ""}

  """
  @spec attributes(t()) :: %{String.t() => String.t()}
  def attributes({_type, %{attributes: attributes}, _children}) do
    Map.new(attributes, fn %{name: name, value: value} -> {String.downcase(name), value || ""} end)
  end

  def attributes(_node), do: %{}

  defp text_iodata(nodes) when is_list(nodes), do: Enum.map(nodes, &text_iodata/1)
  defp text_iodata(text) when is_binary(text), do: text
  defp text_iodata({type, _meta, _children}) when type in [:template, :argument, :comment], do: []
  defp text_iodata({:entity, %{char: char}, _children}), do: char
  defp text_iodata({:link, %{target: target}, []}), do: target
  defp text_iodata({:external_link, %{url: url, brackets: false}, []}), do: url
  defp text_iodata({_type, _meta, children}), do: text_iodata(children)
end
