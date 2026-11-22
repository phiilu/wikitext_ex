defmodule WikitextEx do
  @moduledoc """
  A MediaWiki wikitext parser.

  `parse/2` turns wikitext into a list of nodes, and `to_wikitext/1` turns
  nodes back into wikitext: writing a parsed tree gives back exactly the text it
  was parsed from.

  Text is a plain binary. Every other node is a `{type, meta, children}` tuple,
  the shape of Elixir's own AST, so `Macro.prewalk/2` and friends walk it:

      iex> {:ok, nodes} = WikitextEx.parse("{{Speciesbox|name=Alpine marmot}} is a ''rodent''")
      iex> nodes
      [
        {:template, %{name: "Speciesbox", name_padding: {"", ""}},
         [{:param, %{name: "name", name_padding: {"", ""}, named: true}, ["Alpine marmot"]}]},
        " is a ",
        {:italic, %{}, ["rodent"]}
      ]

  See `WikitextEx.AST` for every node type.
  """

  alias WikitextEx.AST
  alias WikitextEx.Builder
  alias WikitextEx.Tokenizer
  alias WikitextEx.Writer

  @doc """
  Parses `wikitext` into nodes.

  Wikitext has no syntax errors: markup that does not form a construct, such
  as an unclosed `{{`, is text. The only error is input that is not UTF-8.

  ## Options

    * `:skip_style_tags` - when `true`, `''` and `'''` are text rather than
      italic and bold. Defaults to `false`.

  ## Examples

      iex> WikitextEx.parse("[[Großglockner|the highest mountain]]")
      {:ok, [{:link, %{target: "Großglockner", target_padding: {"", ""}, pipe: true}, ["the highest mountain"]}]}

      iex> WikitextEx.parse("{{unclosed")
      {:ok, ["{{unclosed"]}

  """
  @spec parse(String.t(), keyword()) :: {:ok, [AST.t()]} | {:error, :invalid_utf8}
  def parse(wikitext, opts \\ []) when is_binary(wikitext) do
    if String.valid?(wikitext) do
      {:ok,
       wikitext
       |> Tokenizer.tokenize(opts)
       |> Builder.build()}
    else
      {:error, :invalid_utf8}
    end
  end

  @doc """
  Like `parse/2`, but returns the nodes or raises `ArgumentError`.

      iex> WikitextEx.parse!("== History ==")
      [{:heading, %{level: 2}, [" History "]}]

  """
  @spec parse!(String.t(), keyword()) :: [AST.t()]
  def parse!(wikitext, opts \\ []) do
    case parse(wikitext, opts) do
      {:ok, nodes} -> nodes
      {:error, :invalid_utf8} -> raise ArgumentError, "wikitext is not valid UTF-8"
    end
  end

  @doc """
  Writes nodes back to wikitext.

      iex> "{{cite web |url=https://example.org |title=Hohe Tauern National Park}}" |> WikitextEx.parse!() |> WikitextEx.to_wikitext()
      "{{cite web |url=https://example.org |title=Hohe Tauern National Park}}"

  """
  @spec to_wikitext(AST.t() | [AST.t()]) :: String.t()
  defdelegate to_wikitext(nodes), to: Writer
end
