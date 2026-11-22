defmodule WikitextEx.Builder do
  @moduledoc false
  # Builds the node tree out of the tokenizer's token stream, then groups each
  # list marker with the rest of its line.

  alias WikitextEx.Entities
  alias WikitextEx.Text
  alias WikitextEx.Writer

  @attribute_end [:tag_attr_start, :tag_close_open, :tag_close_selfclose]

  @spec build([term()]) :: [WikitextEx.AST.t()]
  def build(tokens) do
    {nodes, []} = nodes_until(tokens, fn _token -> false end)
    group_list_items(nodes)
  end

  # Builds nodes until `stop?` holds for a token, which is left unconsumed.
  defp nodes_until(tokens, stop?, acc \\ [])

  defp nodes_until([], _stop?, acc), do: {Enum.reverse(acc), []}

  defp nodes_until([token | rest] = tokens, stop?, acc) do
    if stop?.(token) do
      {Enum.reverse(acc), tokens}
    else
      {node, rest} = node(token, rest)
      nodes_until(rest, stop?, [node | acc])
    end
  end

  defp is?(types) when is_list(types) do
    fn
      {type, _attrs} -> type in types
      _text -> false
    end
  end

  defp is?(type), do: is?([type])

  defp node(text, rest) when is_binary(text), do: {text, rest}

  defp node({:template_open, _attrs}, tokens) do
    {name_nodes, rest} =
      nodes_until(tokens, is?([:template_param_separator, :template_close]))

    {params, after_params} = params(rest, 1, [])
    {name, padding} = name_and_padding(name_nodes)
    {{:template, %{name: name, name_padding: padding}, params}, after_params}
  end

  defp node({:argument_open, _attrs}, tokens) do
    {name_nodes, default, rest} = split_at_separator(tokens, :argument_separator, :argument_close)
    {name, padding} = name_and_padding(name_nodes)
    meta = %{name: name, name_padding: padding, default: default != nil}
    {{:argument, meta, part_nodes(default)}, rest}
  end

  defp node({:wikilink_open, _attrs}, tokens) do
    {target_nodes, text, rest} = split_at_separator(tokens, :wikilink_separator, :wikilink_close)
    {target, padding} = name_and_padding(target_nodes)

    {{:link, %{target: target, target_padding: padding, pipe: text != nil}, part_nodes(text)},
     rest}
  end

  defp node({:external_link_open, %{brackets: brackets}}, tokens) do
    {url_nodes, title, rest} =
      split_at_separator(tokens, :external_link_separator, :external_link_close)

    meta = %{url: Writer.to_wikitext(url_nodes), brackets: brackets, separator: separator(title)}
    {{:external_link, meta, part_nodes(title)}, rest}
  end

  defp node({:html_entity_start, _attrs}, tokens) do
    {source, codepoint, rest} = entity(tokens)
    {{:entity, %{source: source, char: char(codepoint)}, []}, rest}
  end

  defp node({:heading_start, %{level: level}}, tokens) do
    {title, [{:heading_end, _attrs} | rest]} = nodes_until(tokens, is?(:heading_end))
    {{:heading, %{level: level}, title}, rest}
  end

  defp node({:comment_start, _attrs}, tokens) do
    {content, [{:comment_end, _attrs} | rest]} = nodes_until(tokens, is?(:comment_end))
    {{:comment, %{content: Writer.to_wikitext(content)}, []}, rest}
  end

  defp node({:tag_open_open, open}, tokens) do
    {tag, rest} = tag(tokens, %{name: [], attributes: []})
    {tag_node(open, tag), rest}
  end

  # The entity's source, codepoint, and the tokens after it.
  defp entity([
         {:html_entity_numeric, _attrs},
         {:html_entity_hex, %{char: marker}},
         value,
         _end | rest
       ]), do: {"&#" <> marker <> value <> ";", String.to_integer(value, 16), rest}

  defp entity([{:html_entity_numeric, _attrs}, value, _end | rest]),
    do: {"&#" <> value <> ";", String.to_integer(value), rest}

  defp entity([name, _end | rest]), do: {"&" <> name <> ";", Entities.codepoint(name), rest}

  defp params([{:template_close, _attrs} | rest], _position, acc), do: {Enum.reverse(acc), rest}

  defp params([{:template_param_separator, _attrs} | tokens], position, acc) do
    stop = is?([:template_param_separator, :template_close, :template_param_equals])

    case nodes_until(tokens, stop) do
      {key, [{:template_param_equals, _attrs} | value_tokens]} ->
        {value, rest} =
          nodes_until(value_tokens, is?([:template_param_separator, :template_close]))

        {name, padding} = name_and_padding(key)
        param = {:param, %{name: name, name_padding: padding, named: true}, value}
        params(rest, position, [param | acc])

      {value, rest} ->
        name = Integer.to_string(position)
        param = {:param, %{name: name, name_padding: {"", ""}, named: false}, value}
        params(rest, position + 1, [param | acc])
    end
  end

  # Collects the parts of a tag, up to and including its close.
  defp tag([{:tag_attr_start, pads} | rest], tag) do
    {attribute, rest} = attribute(rest, pads)
    tag(rest, %{tag | attributes: [attribute | tag.attributes]})
  end

  defp tag([{:tag_close_open, attrs} | tokens], tag) do
    {contents, [{:tag_open_close, _attrs} | closing_tokens]} =
      nodes_until(tokens, is?(:tag_open_close))

    {closing_tag, [{:tag_close_close, _attrs} | rest]} =
      nodes_until(closing_tokens, is?(:tag_close_close))

    closed =
      Map.merge(tag, %{
        self_closing: false,
        implicit: false,
        padding: attrs[:padding] || "",
        separator: attrs[:wiki_markup],
        contents: contents,
        closing_tag: Writer.to_wikitext(closing_tag)
      })

    {finish_tag(closed), rest}
  end

  defp tag([{:tag_close_selfclose, attrs} | rest], tag) do
    closed =
      Map.merge(tag, %{
        self_closing: true,
        implicit: attrs[:implicit] || false,
        padding: attrs[:padding] || "",
        separator: nil,
        contents: [],
        closing_tag: nil
      })

    {finish_tag(closed), rest}
  end

  defp tag([token | tokens], tag) do
    {node, rest} = node(token, tokens)
    tag(rest, %{tag | name: [node | tag.name]})
  end

  defp finish_tag(tag) do
    %{
      tag
      | name:
          tag.name
          |> Enum.reverse()
          |> Writer.to_wikitext(),
        attributes: Enum.reverse(tag.attributes)
    }
  end

  # An attribute's name, then an optional `=` and value, the value quoted or not.
  # A value behind an empty name is the attribute's name.
  defp attribute(tokens, pads) do
    {name_nodes, rest} = nodes_until(tokens, is?([:tag_attr_equals | @attribute_end]))
    {value_nodes, quote, after_value} = attribute_value(rest)
    {name, value} = name_and_value(Writer.to_wikitext(name_nodes), value_nodes)

    attribute = %{
      name: name,
      value: value,
      quote: quote,
      pad_first: pads.pad_first,
      pad_before_eq: pads.pad_before_eq,
      pad_after_eq: pads.pad_after_eq
    }

    {attribute, after_value}
  end

  defp attribute_value([{:tag_attr_equals, _attrs}, {:tag_attr_quote, %{char: quote}} | tokens]) do
    {value, rest} = nodes_until(tokens, is?(@attribute_end))
    {value, quote, rest}
  end

  defp attribute_value([{:tag_attr_equals, _attrs} | tokens]) do
    {value, rest} = nodes_until(tokens, is?(@attribute_end))
    {value, nil, rest}
  end

  defp attribute_value(tokens), do: {nil, nil, tokens}

  defp name_and_value("", value) when value != nil, do: {Writer.to_wikitext(value), nil}
  defp name_and_value(name, nil), do: {name, nil}
  defp name_and_value(name, value), do: {name, Writer.to_wikitext(value)}

  defp tag_node(%{wiki_markup: "''"}, tag), do: {:italic, %{}, tag.contents}
  defp tag_node(%{wiki_markup: "'''"}, tag), do: {:bold, %{}, tag.contents}

  defp tag_node(%{wiki_markup: marker}, _tag) when marker in ["*", "#", ";", ":"],
    do: {:list_item, %{marker: marker}, []}

  defp tag_node(%{wiki_markup: "----" <> _dashes = markup}, _tag),
    do: {:hr, %{markup: markup}, []}

  defp tag_node(%{wiki_markup: "{|"}, tag),
    do: {:table, %{attributes: tag.attributes, padding: tag.padding}, tag.contents}

  defp tag_node(%{wiki_markup: "|-"}, tag),
    do: {:table_row, %{attributes: tag.attributes, padding: tag.padding}, tag.contents}

  defp tag_node(%{wiki_markup: markup}, tag) when markup in ["|", "||", "!", "!!"] do
    meta = %{
      header: tag.name == "th",
      markup: markup,
      attributes: tag.attributes,
      padding: tag.padding,
      separator: tag.separator
    }

    {:table_cell, meta, tag.contents}
  end

  defp tag_node(open, tag) do
    meta = %{
      tag: tag.name,
      attributes: tag.attributes,
      self_closing: tag.self_closing,
      padding: tag.padding,
      implicit: tag.implicit,
      invalid: Map.get(open, :invalid, false),
      closing_tag: tag.closing_tag
    }

    {:html_tag, meta, tag.contents}
  end

  # The nodes up to `separator` or `close`, and after a `separator` those up to
  # `close`: `{head, part, rest}`, `part` the separator's attributes and nodes,
  # or `nil` without a separator.
  defp split_at_separator(tokens, separator, close) do
    {head, rest} = nodes_until(tokens, is?([separator, close]))

    case rest do
      [{^separator, attrs} | part_tokens] ->
        {part, [{^close, _attrs} | after_close]} = nodes_until(part_tokens, is?(close))
        {head, {attrs, part}, after_close}

      [{^close, _attrs} | after_close] ->
        {head, nil, after_close}
    end
  end

  defp part_nodes(nil), do: []
  defp part_nodes({_attrs, nodes}), do: nodes

  # An external link's title follows a space, or starts right at the
  # character that ended the URL.
  defp separator(nil), do: nil
  defp separator({attrs, _title}), do: if(attrs[:suppress_space], do: "", else: " ")

  # A name without its surrounding whitespace, and that whitespace.
  defp name_and_padding(nodes) do
    {leading, name, trailing} =
      nodes
      |> Writer.to_wikitext()
      |> Text.split_padding()

    {name, {leading, trailing}}
  end

  defp char(codepoint) when codepoint in 0xD800..0xDFFF, do: "�"
  defp char(codepoint), do: <<codepoint::utf8>>

  # --- List items ---------------------------------------------------------------

  # A list marker opens an item holding the rest of its line: the nodes up to
  # the first newline outside them or the next marker. Markers in a row form
  # one item.
  defp group_list_items(nodes) do
    nodes
    |> Enum.map(&group_children/1)
    |> group_items()
  end

  defp group_children({type, meta, children}), do: {type, meta, group_list_items(children)}
  defp group_children(text), do: text

  defp group_items([{:list_item, %{marker: marker}, []} | nodes]) do
    {markers, line_nodes} = take_markers(nodes, marker)
    {line, rest} = take_line(line_nodes, [])
    [{:list_item, %{marker: markers}, line} | group_items(rest)]
  end

  defp group_items([node | rest]), do: [node | group_items(rest)]
  defp group_items([]), do: []

  defp take_markers([{:list_item, %{marker: next}, []} | rest], marker),
    do: take_markers(rest, marker <> next)

  defp take_markers(rest, marker), do: {marker, rest}

  defp take_line([{:list_item, _meta, []} | _nodes] = rest, acc), do: {Enum.reverse(acc), rest}

  defp take_line([text | rest], acc) when is_binary(text) do
    case :binary.split(text, "\n") do
      [_whole] -> take_line(rest, [text | acc])
      ["", _after] -> {Enum.reverse(acc), [text | rest]}
      [before, after_newline] -> {Enum.reverse([before | acc]), ["\n" <> after_newline | rest]}
    end
  end

  defp take_line([node | rest], acc), do: take_line(rest, [node | acc])
  defp take_line([], acc), do: {Enum.reverse(acc), []}
end
