defmodule WikitextEx.Parser do
  @moduledoc """
  A robust MediaWiki wikitext parser that converts wikitext markup into structured AST nodes.

  This parser supports the complete range of MediaWiki wikitext syntax including:
  - Headers (=, ==, ===, etc.)
  - Templates with named and positional arguments
  - Internal links, categories, files, and interlanguage links
  - Text formatting (bold, italic, combinations)
  - Lists (ordered and unordered with nesting)
  - Tables with headers and data cells
  - HTML tags and comments
  - Reference tags and nowiki sections

  ## Usage

      iex> {:ok, ast, _, _, _, _} = WikitextEx.Parser.parse("'''Bold''' text")
      iex> ast
      [
        %WikitextEx.AST{type: :bold, value: nil, children: [%WikitextEx.AST{type: :text, value: %WikitextEx.AST.Text{content: "Bold"}, children: []}]},
        %WikitextEx.AST{type: :text, value: %WikitextEx.AST.Text{content: " text"}, children: []}
      ]

  ## Parser Architecture

  The parser uses NimbleParsec combinators to build a comprehensive grammar that handles:
  - Proper precedence for nested formatting
  - Context-aware parsing for different wikitext environments
  - Robust error recovery and graceful degradation
  """

  import NimbleParsec

  alias WikitextEx.AST

  optional_whitespace = ascii_string([?\s, ?\t, ?\n, ?\r], min: 0)

  # Common character exclusion sets for text parsing
  @basic_exclusions [not: ?{, not: ?', not: ?[, not: ?<, not: ?*, not: ?#]
  @template_value_exclusions [not: ?{, not: ?|, not: ?}, not: ?\n, not: ?', not: ?[, not: ?<]
  @list_content_exclusions [not: ?{, not: ?', not: ?[, not: ?<, not: ?\n]
  @top_level_exclusions [not: ?{, not: ?', not: ?[, not: ?=, not: ?<, not: ?*, not: ?#]

  # Define inline text first (for use in formatting) - greedy text
  inline_text =
    times(
      choice([
        # Text that doesn't contain formatting or special chars
        utf8_string(@basic_exclusions, min: 1),
        # Single quote not starting formatting
        string("'") |> lookahead_not(string("'")),
        # Single { not starting template
        string("{") |> lookahead_not(string("{")),
        # Single [ not starting link
        string("[") |> lookahead_not(string("[")),
        # Single < not starting HTML tag or comment
        string("<") |> lookahead_not(choice([ascii_char([?a..?z, ?A..?Z, ?/]), string("!--")])),
        # Single * not starting list - avoid consuming consecutive asterisks
        string("*")
        |> lookahead_not(ascii_char([?\s, ?\t]))
        |> lookahead_not(string("*")),
        # Single # not starting list (when not followed by space)
        string("#") |> lookahead_not(ascii_char([?\s, ?\t]))
      ]),
      min: 1
    )
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:text)
    |> reduce({__MODULE__, :to_text, []})

  defparsec(
    :header,
    times(string("="), min: 1, max: 6)
    |> tag(:level)
    |> ignore(optional(ascii_string([?\s], min: 1)))
    |> concat(
      repeat(
        lookahead_not(string("="))
        |> utf8_char([])
      )
      |> tag(:content)
    )
    |> ignore(optional(ascii_string([?\s], min: 1)))
    |> ignore(times(string("="), min: 1, max: 6))
    |> reduce({__MODULE__, :to_header, []})
  )

  defparsec(
    :link,
    ignore(string("[["))
    |> repeat(
      lookahead_not(string("]]"))
      |> utf8_char([])
    )
    |> ignore(string("]]"))
    |> reduce({__MODULE__, :to_link, []})
  )

  name =
    utf8_string([not: ?|, not: ?\n, not: ?\r, not: ?}], min: 1)
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:name)

  defparsec(
    :template_value,
    repeat(
      lookahead_not(string("|"))
      |> lookahead_not(string("}}"))
      |> choice([
        # Bold+italic combination (must come first)
        parsec(:bold_italic_text),
        # Bold formatting  
        parsec(:bold_text),
        # Italic formatting
        parsec(:italic_text),
        # Templates
        parsec(:template),
        # Links
        parsec(:link),
        # HTML tags and comments
        parsec(:html_comment),
        parsec(:container_html_tag),
        parsec(:self_closing_html_tag),
        # Regular text - greedy consumption of text with single quotes that aren't formatting
        times(
          choice([
            # Text that doesn't contain any special chars
            utf8_string(@template_value_exclusions, min: 1),
            # Single quote not starting formatting  
            string("'") |> lookahead_not(string("'")),
            # Single [ not starting link
            string("[") |> lookahead_not(string("["))
          ]),
          min: 1
        )
        |> reduce({List, :to_string, []})
      ])
      |> ignore(ascii_string([?\n, ?\r, ?\t], min: 0))
    )
  )

  key_val =
    ignore(optional_whitespace)
    |> ascii_string([not: ?=, not: ?|, not: ?}, not: ?\n], min: 1)
    |> ignore(optional_whitespace)
    |> ignore(string("="))
    |> ignore(optional_whitespace)
    |> parsec(:template_value)
    |> reduce({__MODULE__, :to_kv, []})

  bare_val =
    ignore(optional_whitespace)
    |> parsec(:template_value)
    |> ignore(optional_whitespace)
    |> reduce({__MODULE__, :to_bare_value, []})

  arg = choice([key_val, bare_val])

  args =
    ignore(string("|"))
    |> concat(arg)
    |> repeat(ignore(string("|")) |> concat(arg))
    |> tag(:args)

  defparsec(
    :template,
    ignore(string("{{"))
    |> ignore(optional_whitespace)
    |> concat(name)
    |> ignore(optional_whitespace)
    |> optional(args)
    |> ignore(optional_whitespace)
    |> ignore(string("}}"))
    |> reduce({__MODULE__, :to_template, []})
  )

  # Content for within italic text (can contain bold)
  italic_content_element =
    choice([
      parsec(:bold_text),
      parsec(:template),
      parsec(:link),
      parsec(:container_html_tag),
      parsec(:self_closing_html_tag),
      inline_text
    ])

  # Content for within bold text (can contain italic)
  bold_content_element =
    choice([
      parsec(:italic_text),
      parsec(:template),
      parsec(:link),
      parsec(:container_html_tag),
      parsec(:self_closing_html_tag),
      inline_text
    ])

  # Content for within bold+italic text (no nested formatting)
  bold_italic_content_element =
    choice([
      parsec(:template),
      parsec(:link),
      parsec(:container_html_tag),
      parsec(:self_closing_html_tag),
      inline_text
    ])

  # Bold+italic (5 apostrophes) - longest match first
  defparsec(
    :bold_italic_text,
    ignore(string("'''''"))
    |> repeat(
      lookahead_not(string("'''''"))
      |> concat(bold_italic_content_element)
    )
    |> ignore(string("'''''"))
    |> reduce({__MODULE__, :to_bold_italic, []})
  )

  # Bold text (3 apostrophes)
  defparsec(
    :bold_text,
    ignore(string("'''"))
    |> repeat(
      lookahead_not(string("'''"))
      |> concat(bold_content_element)
    )
    |> ignore(string("'''"))
    |> reduce({__MODULE__, :to_bold, []})
  )

  # Italic text (2 apostrophes)
  defparsec(
    :italic_text,
    ignore(string("''"))
    |> repeat(
      choice([
        # Don't stop on '' if it's part of ''' (bold)
        lookahead(string("'''"))
        |> concat(italic_content_element),
        # Normal content that doesn't end the italic
        lookahead_not(string("''"))
        |> concat(italic_content_element)
      ])
    )
    |> ignore(string("''"))
    |> reduce({__MODULE__, :to_italic, []})
  )

  # Top-level text element - greedy matcher for continuous text
  text =
    times(
      choice([
        # Continuous text without special chars (exclude < when starting HTML tags or comments)
        utf8_string(@top_level_exclusions, min: 1),
        # Single quote not followed by another quote
        string("'") |> lookahead_not(string("'")),
        # Single { not starting template or table
        string("{") |> lookahead_not(string("{")) |> lookahead_not(string("|")),
        # Single [ not followed by another [
        string("[") |> lookahead_not(string("[")),
        # Single = not followed by another =
        string("=") |> lookahead_not(string("=")),
        # Single < not starting HTML tag or comment
        string("<") |> lookahead_not(choice([ascii_char([?a..?z, ?A..?Z, ?/]), string("!--")])),
        # Single * not starting list - but only when not after newline or at start
        string("*")
        |> lookahead_not(ascii_char([?\s, ?\t]))
        |> lookahead_not(string("*")),
        # Single # not starting list (when not followed by space)
        string("#") |> lookahead_not(ascii_char([?\s, ?\t]))
      ]),
      min: 1
    )
    |> reduce({List, :to_string, []})
    |> unwrap_and_tag(:text)
    |> reduce({__MODULE__, :to_text, []})

  # HTML tag parsing
  tag_name = ascii_string([?a..?z, ?A..?Z], min: 1)

  # HTML attribute parsing: name="value" or name='value' or name=value
  attr_value =
    choice([
      ignore(string(~s("))) |> utf8_string([not: ?\"], min: 0) |> ignore(string(~s("))),
      ignore(string("'")) |> utf8_string([not: ?'], min: 0) |> ignore(string("'")),
      utf8_string([not: ?\s, not: ?\t, not: ?\n, not: ?\r, not: ?>, not: ?/], min: 1)
    ])

  attr_pair =
    tag_name
    |> ignore(string("="))
    |> concat(attr_value)
    |> reduce({__MODULE__, :to_attribute, []})

  attributes =
    repeat(
      ignore(ascii_string([?\s, ?\t], min: 1))
      |> concat(attr_pair)
    )
    |> reduce({__MODULE__, :to_attributes, []})

  # Self-closing ref tags like <ref name="source1" />
  defparsec(
    :self_closing_ref_tag,
    ignore(string("<ref"))
    |> optional(attributes |> unwrap_and_tag(:attributes))
    |> ignore(optional(ascii_string([?\s, ?\t], min: 0)))
    |> ignore(optional(string("/")))
    |> ignore(string(">"))
    |> reduce({__MODULE__, :to_self_closing_ref_tag, []})
  )

  # Self-closing HTML tags like <br> or <br/>
  defparsec(
    :self_closing_html_tag,
    ignore(string("<"))
    |> concat(tag_name |> unwrap_and_tag(:tag))
    |> optional(attributes |> unwrap_and_tag(:attributes))
    |> ignore(optional(ascii_string([?\s, ?\t], min: 0)))
    |> ignore(optional(string("/")))
    |> ignore(string(">"))
    |> reduce({__MODULE__, :to_self_closing_html_tag, []})
  )

  # Container ref tags like <ref>content</ref>
  defparsec(
    :container_ref_tag,
    ignore(string("<ref"))
    |> optional(attributes |> unwrap_and_tag(:attributes))
    |> ignore(optional(ascii_string([?\s, ?\t], min: 0)))
    |> ignore(string(">"))
    |> repeat(
      lookahead_not(string("</ref>"))
      |> choice([
        parsec(:bold_italic_text),
        parsec(:bold_text),
        parsec(:italic_text),
        parsec(:template),
        parsec(:link),
        parsec(:self_closing_ref_tag),
        parsec(:self_closing_html_tag),
        inline_text
      ])
    )
    |> ignore(string("</ref>"))
    |> reduce({__MODULE__, :to_container_ref_tag, []})
  )

  # Container HTML tags like <span>content</span>
  defparsec(
    :container_html_tag,
    ignore(string("<"))
    |> concat(tag_name |> unwrap_and_tag(:tag))
    |> optional(attributes |> unwrap_and_tag(:attributes))
    |> ignore(optional(ascii_string([?\s, ?\t], min: 0)))
    |> ignore(string(">"))
    |> repeat(
      lookahead_not(string("</"))
      |> choice([
        parsec(:bold_italic_text),
        parsec(:bold_text),
        parsec(:italic_text),
        parsec(:template),
        parsec(:link),
        parsec(:self_closing_ref_tag),
        parsec(:self_closing_html_tag),
        inline_text
      ])
    )
    |> ignore(string("</"))
    # closing tag name (we could validate it matches)
    |> ignore(tag_name)
    |> ignore(string(">"))
    |> reduce({__MODULE__, :to_container_html_tag, []})
  )

  # HTML comment parsing: <!-- content -->
  defparsec(
    :html_comment,
    ignore(string("<!--"))
    |> repeat(
      lookahead_not(string("-->"))
      |> utf8_char([])
    )
    |> ignore(string("-->"))
    |> reduce({__MODULE__, :to_html_comment, []})
  )

  # Nowiki tag parsing: <nowiki>content</nowiki>
  defparsec(
    :nowiki_tag,
    ignore(string("<nowiki>"))
    |> repeat(
      lookahead_not(string("</nowiki>"))
      |> utf8_char([])
    )
    |> ignore(string("</nowiki>"))
    |> reduce({__MODULE__, :to_nowiki, []})
  )

  # List item parsing
  list_marker =
    choice([
      times(string("*"), min: 1, max: 10) |> tag(:unordered),
      times(string("#"), min: 1, max: 10) |> tag(:ordered)
    ])

  defparsec(
    :list_item,
    list_marker
    |> ignore(ascii_string([?\s, ?\t], min: 1))
    |> repeat(
      lookahead_not(string("\n"))
      |> choice([
        parsec(:bold_italic_text),
        parsec(:bold_text),
        parsec(:italic_text),
        parsec(:template),
        parsec(:link),
        parsec(:self_closing_ref_tag),
        parsec(:self_closing_html_tag),
        # Text without newlines for list content
        times(
          utf8_string(@list_content_exclusions, min: 1),
          min: 1
        )
        |> reduce({List, :to_string, []})
        |> unwrap_and_tag(:text)
        |> reduce({__MODULE__, :to_text, []})
      ])
    )
    |> reduce({__MODULE__, :to_list_item, []})
  )

  defparsec(
    :table_cell_content,
    repeat(
      choice([
        # HTML tags and formatting
        parsec(:bold_italic_text),
        parsec(:bold_text),
        parsec(:italic_text),
        parsec(:container_html_tag),
        parsec(:self_closing_html_tag),
        # Other wikitext elements
        parsec(:template),
        parsec(:link),
        # Plain text
        times(
          choice([
            utf8_string([not: ?|, not: ?\n, not: ?{, not: ?[, not: ?<, not: ?'], min: 1),
            string("{") |> lookahead_not(string("{")),
            string("[") |> lookahead_not(string("[")),
            string("<")
            |> lookahead_not(choice([ascii_char([?a..?z, ?A..?Z, ?/]), string("!--")])),
            string("'") |> lookahead_not(string("'"))
          ]),
          min: 1
        )
        |> reduce({List, :to_string, []})
      ])
    )
    |> reduce({__MODULE__, :to_cell_content, []})
  )

  defparsec(
    :table_cell_attributes,
    repeat(
      lookahead_not(string(" | "))
      |> lookahead_not(ascii_char([?\n]))
      |> choice([
        parsec(:template),
        utf8_char([])
      ])
    )
  )

  defparsec(
    :table_header_cell,
    ignore(string("!"))
    |> optional(
      parsec(:table_cell_attributes)
      |> ignore(string(" | "))
      |> tag(:attributes)
    )
    |> parsec(:table_cell_content)
    |> reduce({__MODULE__, :to_header_cell, []})
  )

  defparsec(
    :table_data_cell,
    ignore(string("|"))
    |> optional(
      parsec(:table_cell_attributes)
      |> ignore(string(" | "))
      |> tag(:attributes)
    )
    |> parsec(:table_cell_content)
    |> reduce({__MODULE__, :to_data_cell, []})
  )

  defparsec(
    :table,
    ignore(string("{|"))
    |> repeat(
      lookahead_not(string("|}"))
      |> utf8_char([])
    )
    |> ignore(string("|}"))
    |> reduce({__MODULE__, :to_table_with_nimble_parsec, []})
  )

  element =
    choice([
      # Template should be tried early since it's a common and well-defined construct
      parsec(:template),
      parsec(:header),
      # Comments should be parsed before text
      parsec(:html_comment),
      # Nowiki should be parsed before other HTML tags
      parsec(:nowiki_tag),
      # Tables should be parsed before regular text
      parsec(:table),
      parsec(:list_item),
      parsec(:bold_italic_text),
      parsec(:bold_text),
      parsec(:italic_text),
      parsec(:link),
      parsec(:container_ref_tag),
      parsec(:self_closing_ref_tag),
      parsec(:container_html_tag),
      parsec(:self_closing_html_tag),
      text
    ])

  defparsec(
    :parse,
    ignore(optional_whitespace)
    |> times(element, min: 0, max: 10000)
    |> ignore(optional_whitespace)
  )

  # === REDUCTION FUNCTIONS ===

  def to_kv([key, value]) do
    %{key: String.trim(key), value: trim_template_value(value)}
  end

  def to_kv([key | value]) do
    %{key: String.trim(key), value: trim_template_value(value)}
  end

  def to_bare_value(value_list) when is_list(value_list) do
    # Delegate all list handling to trim_template_value
    trim_template_value(value_list)
  end

  def to_template([{:name, name}, {:args, args}]) do
    %AST{type: :template, value: %AST.Template{name: name, args: args_to_map(args)}, children: []}
  end

  def to_template([{:name, name}]) do
    %AST{type: :template, value: %AST.Template{name: name, args: []}, children: []}
  end

  def to_text([{:text, content}]) when is_binary(content) do
    %AST{type: :text, value: %AST.Text{content: content}, children: []}
  end

  def to_text([{:text, [content]}]) do
    %AST{type: :text, value: %AST.Text{content: content}, children: []}
  end

  def to_bold(children) do
    %AST{type: :bold, value: nil, children: children}
  end

  def to_italic(children) do
    %AST{type: :italic, value: nil, children: children}
  end

  def to_bold_italic(children) do
    # Create nested bold and italic AST nodes
    %AST{
      type: :bold,
      value: nil,
      children: [
        %AST{type: :italic, value: nil, children: children}
      ]
    }
  end

  def to_link(chars) when is_list(chars) do
    content = List.to_string(chars)

    case String.split(content, "|", parts: 2) do
      [target] ->
        # No display text, target is both target and display
        parse_link_type(target, target)

      [target, display] ->
        parse_link_type(target, String.trim(display))
    end
  end

  def to_header([{:level, level_strings}, {:content, content_chars} | _closing_equals]) do
    level = length(level_strings)
    content = content_chars |> List.to_string() |> String.trim()

    # Parse the header content to get children AST nodes
    children =
      case __MODULE__.parse(content) do
        {:ok, parsed_children, _, _, _, _} -> parsed_children
        {:error, _, _, _, _, _} -> []
      end

    %AST{
      type: :header,
      value: %AST.Header{level: level},
      children: children
    }
  end

  defp parse_link_type(target, display) do
    target = String.trim(target)

    cond do
      String.starts_with?(target, "Category:") ->
        category_name = String.replace_prefix(target, "Category:", "")
        %AST{type: :category, value: %AST.Category{name: category_name}, children: []}

      String.starts_with?(target, "File:") ->
        file_name = String.replace_prefix(target, "File:", "")
        # Parse parameters from display (e.g., "40px", "thumb", etc.)
        parameters =
          if display && display != file_name do
            String.split(display, "|")
          else
            []
          end

        %AST{type: :file, value: %AST.File{name: file_name, parameters: parameters}, children: []}

      # Interlang links (e.g., [[de:Page]], [[ja:ページ]])
      Regex.match?(~r/^[a-z]{2,3}:/, target) ->
        [lang, title] = String.split(target, ":", parts: 2)

        %AST{
          type: :interlang_link,
          value: %AST.InterlangLink{lang: lang, title: title},
          children: []
        }

      # Regular internal link
      true ->
        %AST{type: :link, value: %AST.Link{target: target, display: display}, children: []}
    end
  end

  defp args_to_map(args) do
    args
    |> Enum.map(fn
      %{key: key, value: value} -> {:named, %{key => value}}
      bare_value -> {:positional, bare_value}
    end)
    |> Enum.filter(&is_meaningful_argument?/1)
  end

  # Filter out empty or meaningless arguments
  defp is_meaningful_argument?({:named, map}) when map_size(map) == 0, do: false

  defp is_meaningful_argument?({:named, map}),
    do: map |> Map.values() |> Enum.any?(&meaningful_value?/1)

  defp is_meaningful_argument?({:positional, value}), do: meaningful_value?(value)

  # Check if a value is meaningful (not empty/whitespace)
  defp meaningful_value?(str) when is_binary(str), do: String.trim(str) != ""
  defp meaningful_value?([]), do: false
  defp meaningful_value?(%AST{}), do: true
  defp meaningful_value?(list) when is_list(list), do: Enum.any?(list, &meaningful_value?/1)
  defp meaningful_value?(_), do: true

  def to_attribute([name, value]) do
    {name, value}
  end

  def to_attributes(attrs) do
    Map.new(attrs)
  end

  def to_self_closing_html_tag([{:tag, tag}]) do
    create_html_tag_ast(tag, %{}, [])
  end

  def to_self_closing_html_tag([{:tag, tag}, {:attributes, attributes}]) do
    create_html_tag_ast(tag, attributes, [])
  end

  def to_container_html_tag([{:tag, tag}, {:attributes, attributes} | children]) do
    create_html_tag_ast(tag, attributes, children)
  end

  def to_container_html_tag([{:tag, tag} | children]) do
    create_html_tag_ast(tag, %{}, children)
  end

  def to_list_item([{list_type, markers} | children]) when list_type in [:unordered, :ordered] do
    level = if is_list(markers), do: length(markers), else: String.length(markers)
    create_list_item_ast(list_type, level, children)
  end

  def to_html_comment(chars) when is_list(chars) do
    content = List.to_string(chars)

    %AST{
      type: :comment,
      value: %AST.Comment{content: content},
      children: []
    }
  end

  def to_self_closing_ref_tag([]) do
    create_ref_ast(%{}, [])
  end

  def to_self_closing_ref_tag([{:attributes, attributes}]) do
    create_ref_ast(attributes, [])
  end

  def to_container_ref_tag([{:attributes, attributes} | children]) do
    create_ref_ast(attributes, children)
  end

  def to_container_ref_tag(children) do
    create_ref_ast(%{}, children)
  end

  def to_nowiki(chars) when is_list(chars) do
    content = List.to_string(chars)

    %AST{
      type: :nowiki,
      value: %AST.Nowiki{content: content},
      children: []
    }
  end

  def to_table_with_nimble_parsec(chars) when is_list(chars) do
    content = List.to_string(chars)

    # Now use NimbleParsec to parse the table content properly
    rows = parse_table_content_with_nimble_parsec(content)

    %AST{
      type: :table,
      value: %AST.Table{attributes: %{}},
      children: rows
    }
  end

  defp parse_table_content_with_nimble_parsec(content) do
    content
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> group_lines_into_rows([], [])
    |> Enum.map(&parse_table_row_group/1)
  end

  defp group_lines_into_rows([], current_group, acc) do
    if length(current_group) > 0 do
      Enum.reverse([Enum.reverse(current_group) | acc])
    else
      Enum.reverse(acc)
    end
  end

  defp group_lines_into_rows([line | rest], current_group, acc) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "|-") ->
        new_acc = if length(current_group) > 0, do: [Enum.reverse(current_group) | acc], else: acc
        group_lines_into_rows(rest, [], new_acc)

      String.starts_with?(trimmed, "!") ->
        group_lines_into_rows(rest, [line | current_group], acc)

      String.starts_with?(trimmed, "|") ->
        group_lines_into_rows(rest, [line | current_group], acc)

      true ->
        group_lines_into_rows(rest, current_group, acc)
    end
  end

  defp parse_table_row_group(lines) do
    first_line = hd(lines)
    trimmed = String.trim(first_line)

    if String.starts_with?(trimmed, "!") do
      cells = Enum.map(lines, &parse_header_line_with_nimble/1)
      create_header_row(cells)
    else
      cells = Enum.map(lines, &parse_data_line_with_nimble/1)
      create_data_row(cells)
    end
  end

  defp parse_header_line_with_nimble(line) do
    case __MODULE__.table_header_cell(line) do
      {:ok, [cell], _, _, _, _} ->
        cell

      _ ->
        content =
          line |> String.trim() |> String.replace_prefix("!", "") |> extract_cell_content_simple()

        create_header_cell_simple(content)
    end
  end

  defp parse_data_line_with_nimble(line) do
    case __MODULE__.table_data_cell(line) do
      {:ok, [cell], _, _, _, _} ->
        cell

      _ ->
        content = line |> String.trim() |> String.replace_prefix("|", "") |> String.trim()
        create_data_cell_with_parsing(content)
    end
  end

  defp extract_cell_content_simple(text) do
    case String.split(text, " | ", parts: 2) do
      [_style, content] -> String.trim(content)
      [content] -> String.trim(content)
    end
  end

  defp create_header_row(cells) do
    %AST{
      type: :table_row,
      value: %AST.TableRow{attributes: %{}},
      children: cells
    }
  end

  defp create_data_row(cells) do
    %AST{
      type: :table_row,
      value: %AST.TableRow{attributes: %{}},
      children: cells
    }
  end

  defp create_header_cell_simple(content) do
    %AST{
      type: :table_cell,
      value: %AST.TableCell{type: :header, attributes: %{}},
      children: [%AST{type: :text, value: %AST.Text{content: content}, children: []}]
    }
  end

  defp create_data_cell_with_parsing(content) do
    children =
      case __MODULE__.parse(content) do
        {:ok, parsed, _, _, _, _} ->
          parsed

        {:error, _, _, _, _, _} ->
          [%AST{type: :text, value: %AST.Text{content: content}, children: []}]
      end

    %AST{
      type: :table_cell,
      value: %AST.TableCell{type: :data, attributes: %{}},
      children: children
    }
  end

  def to_cell_content(content_parts) do
    content_parts
    |> List.flatten()
    |> Enum.map(fn
      %AST{} = ast ->
        ast

      str when is_binary(str) ->
        %AST{type: :text, value: %AST.Text{content: String.trim(str)}, children: []}

      chars when is_list(chars) ->
        %AST{
          type: :text,
          value: %AST.Text{content: List.to_string(chars) |> String.trim()},
          children: []
        }
    end)
    |> Enum.filter(fn
      %AST{type: :text, value: %AST.Text{content: ""}} -> false
      _ -> true
    end)
  end

  def to_header_cell([content]) do
    %AST{
      type: :table_cell,
      value: %AST.TableCell{type: :header, attributes: %{}},
      children: ensure_content_list(content)
    }
  end

  def to_header_cell([{:attributes, _attrs}, content]) do
    # TODO: Parse and store table cell attributes (currently ignored)
    %AST{
      type: :table_cell,
      value: %AST.TableCell{type: :header, attributes: %{}},
      children: ensure_content_list(content)
    }
  end

  def to_data_cell([content]) do
    %AST{
      type: :table_cell,
      value: %AST.TableCell{type: :data, attributes: %{}},
      children: ensure_content_list(content)
    }
  end

  def to_data_cell([{:attributes, _attrs}, content]) do
    # TODO: Parse and store table cell attributes (currently ignored)
    %AST{
      type: :table_cell,
      value: %AST.TableCell{type: :data, attributes: %{}},
      children: ensure_content_list(content)
    }
  end

  defp ensure_content_list(content) when is_list(content), do: content
  defp ensure_content_list(content), do: [content]

  # === HELPER FUNCTIONS ===

  defp create_html_tag_ast(tag, attributes, children) do
    %AST{
      type: :html_tag,
      value: %AST.HtmlTag{tag: tag, attributes: attributes},
      children: children
    }
  end

  defp create_list_item_ast(list_type, level, children) do
    %AST{
      type: :list_item,
      value: %AST.ListItem{type: list_type, level: level},
      children: children
    }
  end

  defp create_ref_ast(attributes, children) do
    %AST{
      type: :ref,
      value: %AST.Ref{
        name: Map.get(attributes, "name"),
        group: Map.get(attributes, "group")
      },
      children: children
    }
  end

  # Trim template values only when they're simple strings at the end
  defp trim_template_value(value) when is_binary(value) do
    String.trim(value)
  end

  defp trim_template_value(value_list) when is_list(value_list) do
    # Efficient single-pass: find the last meaningful element
    trimmed_list = trim_from_end(value_list)

    # If we have a single element, return just the element
    case trimmed_list do
      [single_element] -> single_element
      _ -> trimmed_list
    end
  end

  defp trim_template_value(value), do: value

  # Remove trailing whitespace without double reverse
  defp trim_from_end([]), do: []

  defp trim_from_end([head | tail]) do
    case trim_from_end(tail) do
      [] -> if is_binary(head) and String.trim(head) == "", do: [], else: [head]
      result -> [head | result]
    end
  end
end
