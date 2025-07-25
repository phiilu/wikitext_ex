defmodule WikitextEx.AST do
  @moduledoc """
  Abstract Syntax Tree (AST) structure for WikitextEx parser.

  This module defines the AST node structure and all the specific node types
  that represent different wikitext elements. Each AST node has:

  - `type`: An atom indicating the kind of element (`:text`, `:template`, `:link`, etc.)
  - `value`: Type-specific data stored in structured format
  - `children`: List of nested AST nodes for container elements

  ## Example

      %WikitextEx.AST{
        type: :template,
        value: %WikitextEx.AST.Template{name: "cite", args: [...]},
        children: []
      }

  ## Node Types

  The parser produces these AST node types:

  - Text elements: `:text`
  - Structure: `:header`, `:list_item`, `:table`, `:table_row`, `:table_cell`
  - Formatting: `:bold`, `:italic`
  - Links: `:link`, `:category`, `:file`, `:interlang_link`
  - Templates: `:template`
  - HTML: `:html_tag`, `:comment`, `:ref`, `:nowiki`
  """

  # Public types
  @type type() ::
          atom()

  @type value() ::
          WikitextEx.AST.Header.t()
          | WikitextEx.AST.Text.t()
          | WikitextEx.AST.Template.t()
          | WikitextEx.AST.Link.t()
          | WikitextEx.AST.Category.t()
          | WikitextEx.AST.InterlangLink.t()
          | WikitextEx.AST.HtmlTag.t()
          | WikitextEx.AST.ListItem.t()
          | WikitextEx.AST.Comment.t()
          | WikitextEx.AST.Ref.t()
          | WikitextEx.AST.Nowiki.t()
          | WikitextEx.AST.Table.t()
          | WikitextEx.AST.TableRow.t()
          | WikitextEx.AST.TableCell.t()
          | nil

  @type t() :: %__MODULE__{
          type: type(),
          value: value(),
          children: [t()]
        }

  defstruct [:type, :value, :children]

  @doc """
  Extract text content from AST children, useful for headers and other containers.
  """
  def text_content(children) when is_list(children) do
    children
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map(& &1.value.content)
    |> Enum.join("")
    |> String.trim()
  end

  # Handle text nodes directly
  def text_content(%__MODULE__{type: :text, value: %{content: content}}), do: content

  def text_content(%__MODULE__{children: children}), do: text_content(children)

  defmodule Header do
    @moduledoc "A level‐N header"
    @type t() :: %__MODULE__{
            level: non_neg_integer()
          }

    defstruct [:level]
  end

  defmodule Text do
    @moduledoc "Plain text node"
    @type t() :: %__MODULE__{content: String.t()}
    defstruct [:content]
  end

  defmodule Template do
    @moduledoc "A template invocation with name and keyword args"
    @type args() :: [{String.t(), String.t()}]
    @type t() :: %__MODULE__{
            name: String.t(),
            args: args()
          }
    defstruct [:name, :args]
  end

  defmodule Link do
    @moduledoc "A wiki link: target page and optional display text"
    @type t() :: %__MODULE__{
            target: String.t(),
            display: String.t() | nil
          }
    defstruct [:target, :display]
  end

  defmodule File do
    @moduledoc "A file embedding: name and optional parameters"
    @type t() :: %__MODULE__{
            name: String.t(),
            parameters: [String.t()]
          }
    defstruct [:name, :parameters]
  end

  defmodule Category do
    @moduledoc "A category inclusion"
    @type t() :: %__MODULE__{name: String.t()}
    defstruct [:name]
  end

  defmodule InterlangLink do
    @moduledoc "An inter‐language link"
    @type t() :: %__MODULE__{
            lang: String.t(),
            title: String.t()
          }
    defstruct [:lang, :title]
  end

  defmodule HtmlTag do
    @moduledoc "An HTML tag with optional attributes"
    @type t() :: %__MODULE__{
            tag: String.t(),
            attributes: map()
          }
    defstruct [:tag, :attributes]
  end

  defmodule ListItem do
    @moduledoc "A list item (ordered or unordered) with nesting level"
    @type list_type() :: :ordered | :unordered
    @type t() :: %__MODULE__{
            type: list_type(),
            level: pos_integer()
          }
    defstruct [:type, :level]
  end

  defmodule Comment do
    @moduledoc "An HTML comment"
    @type t() :: %__MODULE__{content: String.t()}
    defstruct [:content]
  end

  defmodule Ref do
    @moduledoc "A reference tag with optional name and group"
    @type t() :: %__MODULE__{
            name: String.t() | nil,
            group: String.t() | nil
          }
    defstruct [:name, :group]
  end

  defmodule Nowiki do
    @moduledoc "Nowiki content that should not be parsed"
    @type t() :: %__MODULE__{content: String.t()}
    defstruct [:content]
  end

  defmodule Table do
    @moduledoc "A MediaWiki table with optional attributes"
    @type t() :: %__MODULE__{
            attributes: map()
          }
    defstruct [:attributes]
  end

  defmodule TableRow do
    @moduledoc "A table row with optional attributes"
    @type t() :: %__MODULE__{
            attributes: map()
          }
    defstruct [:attributes]
  end

  defmodule TableCell do
    @moduledoc "A table cell (header or data) with optional attributes"
    @type cell_type() :: :header | :data
    @type t() :: %__MODULE__{
            type: cell_type(),
            attributes: map()
          }
    defstruct [:type, :attributes]
  end
end
