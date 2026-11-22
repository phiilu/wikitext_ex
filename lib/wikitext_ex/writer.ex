defmodule WikitextEx.Writer do
  @moduledoc false
  # Writes nodes back to wikitext. A parsed tree is written back to exactly the
  # text it was parsed from.

  @spec to_wikitext(WikitextEx.AST.t() | [WikitextEx.AST.t()]) :: String.t()
  def to_wikitext(nodes) do
    nodes
    |> write()
    |> IO.iodata_to_binary()
  end

  defp write(nodes) when is_list(nodes), do: Enum.map(nodes, &write/1)
  defp write(text) when is_binary(text), do: text

  defp write({:template, meta, params}) do
    ["{{", padded(meta.name, meta[:name_padding]), Enum.map(params, &["|", write(&1)]), "}}"]
  end

  defp write({:param, %{named: true} = meta, value}),
    do: [padded(meta.name, meta[:name_padding]), "=", write(value)]

  defp write({:param, _meta, value}), do: write(value)

  defp write({:argument, meta, default}) do
    separated_default = if meta[:default] || default != [], do: ["|", write(default)], else: []
    ["{{{", padded(meta.name, meta[:name_padding]), separated_default, "}}}"]
  end

  defp write({:link, meta, text}) do
    piped_text = if meta[:pipe] || text != [], do: ["|", write(text)], else: []
    ["[[", padded(meta.target, meta[:target_padding]), piped_text, "]]"]
  end

  defp write({:external_link, %{brackets: false} = meta, _title}), do: meta.url

  defp write({:external_link, meta, title}) do
    separated_title =
      case {meta[:separator], title} do
        {nil, []} -> []
        {nil, _title} -> [" ", write(title)]
        {separator, _title} -> [separator, write(title)]
      end

    ["[", meta.url, separated_title, "]"]
  end

  defp write({:heading, %{level: level}, title}) do
    equals = String.duplicate("=", level)
    [equals, write(title), equals]
  end

  defp write({:comment, %{content: content}, _children}), do: ["<!--", content, "-->"]
  defp write({:entity, %{source: source}, _children}), do: source
  defp write({:italic, _meta, children}), do: ["''", write(children), "''"]
  defp write({:bold, _meta, children}), do: ["'''", write(children), "'''"]
  defp write({:list_item, %{marker: marker}, children}), do: [marker, write(children)]
  defp write({:hr, meta, _children}), do: Map.get(meta, :markup, "----")

  defp write({:table, meta, children}) do
    ["{|", attributes(meta), Map.get(meta, :padding, "\n"), write(children), "|}"]
  end

  defp write({:table_row, meta, children}) do
    ["|-", attributes(meta), Map.get(meta, :padding, "\n"), write(children)]
  end

  defp write({:table_cell, meta, children}) do
    markup = meta[:markup] || if(meta[:header], do: "!", else: "|")
    separator = meta[:separator] || if(meta[:attributes] in [nil, []], do: "", else: "|")
    [markup, attributes(meta), Map.get(meta, :padding, ""), separator, write(children)]
  end

  defp write({:html_tag, meta, children}) do
    open = if meta[:invalid], do: "</", else: "<"
    padding = Map.get(meta, :padding, "")

    if meta[:self_closing] do
      [open, meta.tag, attributes(meta), padding, if(meta[:implicit], do: ">", else: "/>")]
    else
      closing_tag = meta[:closing_tag] || meta.tag
      [open, meta.tag, attributes(meta), padding, ">", write(children), "</", closing_tag, ">"]
    end
  end

  defp attributes(meta) do
    meta
    |> Map.get(:attributes, [])
    |> Enum.map(&attribute/1)
  end

  defp attribute(%{name: name} = attribute) do
    value =
      case attribute[:value] do
        nil -> []
        value -> ["=", attribute[:pad_after_eq] || "", quoted(value, attribute[:quote])]
      end

    [Map.get(attribute, :pad_first, " "), name, attribute[:pad_before_eq] || "", value]
  end

  defp quoted(value, nil), do: value
  defp quoted(value, quote), do: [quote, value, quote]

  defp padded(name, {leading, trailing}), do: [leading, name, trailing]
  defp padded(name, nil), do: name
end
