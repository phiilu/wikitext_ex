defmodule WikitextEx.Tokenizer do
  @moduledoc false
  # Splits wikitext into tokens: text, and the markup of the constructs in it.
  #
  # Wikitext has no syntax errors. Markup that does not complete a construct is
  # text: `{{` without its `}}`, `[[` across a line break, `''` never closed. So
  # the tokenizer reads a construct as far as it can, and when the construct
  # does not hold up, backtracks and reads its opening as text (see
  # `WikitextEx.Tokenizer.State`).
  #
  # What a character means depends on where it is: `|` separates template
  # parameters, starts a table cell at the start of a line, and is text
  # elsewhere. Each frame carries a context of the flags below for this.
  #
  # Every function reading markup returns the state positioned at the next
  # character to read. Text tokens are binaries; all others are `{type, attrs}`.

  import Bitwise
  import WikitextEx.Tokenizer.State, only: [nestable: 1]

  alias WikitextEx.Entities
  alias WikitextEx.Text
  alias WikitextEx.Tokenizer.State

  # Frame contexts
  @template_name 1 <<< 0
  @template_param_key 1 <<< 1
  @template_param_value 1 <<< 2
  @template @template_name ||| @template_param_key ||| @template_param_value
  @argument_name 1 <<< 3
  @argument_default 1 <<< 4
  @argument @argument_name ||| @argument_default
  @wikilink_title 1 <<< 5
  @wikilink_text 1 <<< 6
  @wikilink @wikilink_title ||| @wikilink_text
  @ext_link_uri 1 <<< 7
  @ext_link_title 1 <<< 8
  @ext_link @ext_link_uri ||| @ext_link_title
  @heading_level_1 1 <<< 9
  @heading 0b111111 <<< 9
  @tag_open 1 <<< 15
  @tag_attr 1 <<< 16
  @tag_body 1 <<< 17
  @tag_close 1 <<< 18
  @tag @tag_open ||| @tag_attr ||| @tag_body ||| @tag_close
  @style_italics 1 <<< 19
  @style_bold 1 <<< 20
  @style_pass_again 1 <<< 21
  @style_second_pass 1 <<< 22
  @style @style_italics ||| @style_bold ||| @style_pass_again ||| @style_second_pass
  @dl_term 1 <<< 23
  # Set while reading a template name, to tell a name from a stray `{{`.
  @has_text 1 <<< 24
  @fail_on_text 1 <<< 25
  @fail_next 1 <<< 26
  @fail_on_lbrace 1 <<< 27
  @fail_on_rbrace 1 <<< 28
  @fail_on_equals 1 <<< 29
  @has_template 1 <<< 30
  @table_open 1 <<< 31
  @table_cell_open 1 <<< 32
  @table_cell_style 1 <<< 33
  @table_row_open 1 <<< 34
  @table_td_line 1 <<< 35
  @table_th_line 1 <<< 36
  @table_cell_line @table_td_line ||| @table_th_line ||| @table_cell_style
  @html_entity 1 <<< 37

  # Constructs that fail when the text ends inside them.
  @unterminated_fails @template ||| @argument ||| @wikilink ||| @ext_link_title ||| @heading |||
                        @tag ||| @style ||| @table_open
  # Contexts in which some characters end the construct, checked one by one.
  # A closing tag is not one of them: its name is checked at its `>`.
  @unsafe @template_name ||| @wikilink_title ||| @ext_link_title ||| @template_param_key |||
            @argument_name
  # Contexts read in a frame of their own on top of the construct's frame.
  @double @template_param_key ||| @tag_close ||| @table_row_open
  @no_wikilinks @template_name ||| @argument_name ||| @wikilink_title ||| @ext_link_uri
  @no_ext_links @template_name ||| @argument_name ||| @wikilink_title ||| @ext_link

  # Tag reading contexts
  @tag_name 1 <<< 0
  @tag_attr_ready 1 <<< 1
  @tag_attr_name 1 <<< 2
  @tag_attr_value 1 <<< 3
  @tag_quoted 1 <<< 4
  @tag_note_space 1 <<< 5
  @tag_note_equals 1 <<< 6
  @tag_note_quote 1 <<< 7

  @markers ~c"{}[]<>|=&'#*;:/-!\n"
  @list_markers ~c"#*;:"
  @uri_scheme_chars ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+.-"
  @free_link_punctuation ~c",;\\.:!?"

  # URI schemes MediaWiki links, and whether a link needs `//` after them.
  @uri_schemes %{
    "bitcoin" => false,
    "ftp" => true,
    "ftps" => true,
    "geo" => false,
    "git" => true,
    "gopher" => true,
    "http" => true,
    "https" => true,
    "irc" => true,
    "ircs" => true,
    "magnet" => false,
    "mailto" => false,
    "mms" => true,
    "news" => false,
    "nntp" => true,
    "redis" => true,
    "sftp" => true,
    "sip" => false,
    "sips" => false,
    "sms" => false,
    "ssh" => true,
    "svn" => true,
    "tel" => false,
    "telnet" => true,
    "urn" => false,
    "worldwind" => true,
    "xmpp" => false
  }

  # Tags whose contents are not wikitext.
  @unparsed_tags ~w(categorytree ce chem gallery graph hiero imagemap inputbox math nowiki pre
                    score section source syntaxhighlight templatedata timeline)
  # Tags that never have contents, and tags whose close MediaWiki supplies.
  @void_tags ~w(br wbr hr meta link img)
  @optional_close_tags @void_tags ++ ~w(li dt dd th td tr)
  # Entities longer than this are text.
  @max_entity_length 8
  @list_tags %{?# => "li", ?* => "li", ?; => "dt", ?: => "dd"}

  defguardp has(context, flag) when band(context, flag) != 0
  defguardp marker(char) when char in @markers or char in [:start, :end]
  defguardp line_start(char) when char in [?\n, :start]
  defguardp in_heading(s) when :erlang.map_get(:heading?, s)

  @spec tokenize(String.t(), keyword()) :: [term()]
  def tokenize(text, opts \\ []) do
    s = State.new(text, Keyword.get(opts, :skip_style_tags, false))

    case State.attempt(s, &parse(&1, 0)) do
      {:ok, {tokens, %State{frames: []}}} -> tokens
    end
  end

  # Reads with `context` until its construct ends, returning `{result, s}`:
  # the construct's tokens, or for a heading `{title_tokens, level}`.
  defp parse(s, context, opts \\ []) do
    if Keyword.get(opts, :push, true) do
      s
      |> State.push(context)
      |> read()
    else
      read(s)
    end
  end

  defp read(s) do
    char = State.current(s)

    if has(State.context(s), @unsafe) do
      s
      |> verify_safe(char)
      |> read_unsafe(char)
    else
      read_char(s, char)
    end
  end

  # Where some characters end the construct, text is read one character at a
  # time, each checked.
  defp read_unsafe(s, char) when char in @markers or char == :end, do: read_char(s, char)

  defp read_unsafe(s, char) do
    s
    |> State.emit_char(char)
    |> State.forward()
    |> read()
  end

  defp read_char(s, :end), do: finish(s)

  defp read_char(s, char) when char in @markers do
    case markup(s, State.ahead(s, 4), State.behind(s, 1), State.context(s)) do
      {:done, result, done} -> {result, done}
      %State{} = next -> read(next)
    end
  end

  defp read_char(s, _char) do
    text = State.text_run(s, &(&1 in @markers))

    s
    |> State.emit_text(text)
    |> State.seek(s.pos + byte_size(text))
    |> read()
  end

  # The text ends inside the current construct.
  defp finish(s) do
    context = State.context(s)

    cond do
      not has(context, @unterminated_fails) ->
        State.pop(s)

      has(context, @tag_body) and optional_close?(tag_name(s)) ->
        close_tag_implicitly(s)

      true ->
        s
        |> drop_if(@table_cell_open)
        |> drop_if(@double)
        |> State.fail()
    end
  end

  # Drops the current frame when its context has one of `flags`: a frame read
  # on top of its construct's, which fails with it.
  defp drop_if(s, flags) do
    if has(State.context(s), flags), do: State.drop(s), else: s
  end

  # Fails the construct on a character it cannot hold, noting characters that
  # may end it on the next one.
  defp verify_safe(s, char) do
    case safety(s, char, State.context(s)) do
      :unsafe ->
        s
        |> drop_if(@double)
        |> State.fail()

      :safe ->
        s

      {:note, flags} ->
        State.add_flags(s, flags)

      {:toggle, flags} ->
        State.toggle_flags(s, flags)
    end
  end

  defp safety(_s, _char, context) when has(context, @fail_next), do: :unsafe

  defp safety(s, char, context) when has(context, @wikilink_title) do
    cond do
      char in [?], ?{] -> {:note, @fail_next}
      char in [?\n, ?[, ?}, ?>] -> :unsafe
      char == ?< and State.peek(s, 1) == ?! -> {:note, @fail_next}
      char == ?< -> :unsafe
      true -> :safe
    end
  end

  defp safety(_s, char, context) when has(context, @ext_link_title),
    do: if(char == ?\n, do: :unsafe, else: :safe)

  defp safety(s, char, context) when has(context, @template_name),
    do: template_name_safety(s, char, context)

  defp safety(_s, char, context) when has(context, @fail_on_equals),
    do: if(char == ?=, do: :unsafe, else: :safe)

  defp safety(s, char, context) when has(context, @fail_on_lbrace) do
    if char == ?{ or (State.behind(s, 1) == ?{ and State.behind(s, 2) == ?{) do
      if has(context, @template), do: {:note, @fail_on_equals}, else: {:note, @fail_next}
    else
      {:toggle, @fail_on_lbrace}
    end
  end

  defp safety(_s, char, context) when has(context, @fail_on_rbrace),
    do: if(char == ?}, do: {:note, @fail_next}, else: {:toggle, @fail_on_rbrace})

  defp safety(_s, ?{, _context), do: {:note, @fail_on_lbrace}
  defp safety(_s, ?}, _context), do: {:note, @fail_on_rbrace}
  defp safety(_s, _char, _context), do: :safe

  # A template's name: text, a `{{` inside it, or whitespace around it.
  defp template_name_safety(_s, ?{, _context), do: {:note, @has_template ||| @fail_next}
  defp template_name_safety(_s, ?}, _context), do: {:note, @fail_next}

  defp template_name_safety(s, ?<, _context),
    do: if(State.peek(s, 1) == ?!, do: {:note, @fail_next}, else: :unsafe)

  defp template_name_safety(_s, char, _context) when char in [?[, ?], ?>], do: :unsafe
  defp template_name_safety(_s, ?|, _context), do: :safe

  defp template_name_safety(_s, char, context) when has(context, @has_text),
    do: after_template_name_safety(char, context)

  defp template_name_safety(_s, char, _context),
    do: if(State.space?(char), do: :safe, else: {:note, @has_text})

  # After a line break, only whitespace may follow a template's name.
  defp after_template_name_safety(char, context) when has(context, @fail_on_text),
    do: if(State.space?(char), do: :safe, else: :unsafe)

  defp after_template_name_safety(?\n, _context), do: {:note, @fail_on_text}
  defp after_template_name_safety(_char, _context), do: :safe

  # --- Markup -------------------------------------------------------------------

  # Reads the markup at the position, given the next four characters, the one
  # before, and the context. Returns the state, or `{:done, result, s}` when the
  # markup ends the construct being read.
  defp markup(s, [?{, ?{ | _ahead], _last, _context) when nestable(s), do: template_or_argument(s)
  defp markup(s, [?{, ?{ | _ahead], _last, _context), do: text_char(s)

  defp markup(s, [?| | _ahead], _last, context) when has(context, @template),
    do: template_param(s)

  defp markup(s, [?=, next | _ahead], last, context) when has(context, @template_param_key) do
    if not s.heading? and line_start(last) and next == ?=,
      do: heading(s),
      else: template_param_value(s)
  end

  defp markup(s, [?}, ?} | _ahead], _last, context) when has(context, @template),
    do: template_end(s)

  defp markup(s, [?| | _ahead], _last, context) when has(context, @argument_name),
    do: argument_separator(s)

  defp markup(s, [?}, ?}, third | _ahead], _last, context) when has(context, @argument) do
    if third == ?}, do: argument_end(s), else: text_char(s)
  end

  defp markup(s, [?[, ?[ | _ahead], _last, context) when nestable(s) do
    if has(context, @no_wikilinks), do: text_char(s), else: wikilink(s)
  end

  defp markup(s, [?| | _ahead], _last, context) when has(context, @wikilink_title),
    do: wikilink_separator(s)

  defp markup(s, [?], ?] | _ahead], _last, context) when has(context, @wikilink),
    do: wikilink_end(s)

  defp markup(s, [?[ | _ahead], _last, _context), do: external_link(s, true)
  defp markup(s, [?: | _ahead], last, _context) when not marker(last), do: external_link(s, false)

  defp markup(s, [?] | _ahead], _last, context) when has(context, @ext_link_title) do
    s
    |> State.forward()
    |> State.pop()
    |> done()
  end

  defp markup(s, [?= | _ahead], last, context)
       when not in_heading(s) and not has(context, @template) do
    if line_start(last), do: heading(s), else: text_char(s)
  end

  defp markup(s, [?= | _ahead], _last, context) when has(context, @heading), do: heading_end(s)
  defp markup(s, [?\n | _ahead], _last, context) when has(context, @heading), do: State.fail(s)
  defp markup(s, [?& | _ahead], _last, _context), do: entity(s)

  defp markup(s, [?<, ?!, third, fourth], _last, _context) do
    if third == ?- and fourth == ?-, do: comment(s), else: text_char(s)
  end

  defp markup(s, [?<, ?/, third | _ahead], _last, context) when third != :end do
    if has(context, @tag_body), do: closing_tag_open(s), else: invalid_tag_start(s)
  end

  defp markup(s, [?< | _ahead], _last, context) when not has(context, @tag_close) and nestable(s),
    do: tag(s)

  defp markup(s, [?< | _ahead], _last, context) when not has(context, @tag_close),
    do: text_char(s)

  defp markup(s, [?> | _ahead], _last, context) when has(context, @tag_close),
    do: closing_tag_close(s)

  defp markup(%{skip_style_tags?: false} = s, [?', ?' | _ahead], _last, _context), do: style(s)

  defp markup(s, [char | _ahead], last, _context) when line_start(last) and char in @list_markers,
    do: list(s)

  defp markup(s, [?-, ?-, ?-, ?-], last, _context) when line_start(last), do: horizontal_rule(s)

  defp markup(s, [char | _ahead], _last, context)
       when char in [?\n, ?:] and has(context, @dl_term) do
    s = definition_term_end(s)
    if char == ?\n, do: State.remove_flags(s, @table_cell_line), else: s
  end

  defp markup(s, [?{, ?| | _ahead] = ahead, last, context) do
    cond do
      not leading_whitespace?(s) -> table_markup(s, ahead, last, context)
      nestable(s) -> table(s)
      true -> text_char(s)
    end
  end

  defp markup(s, ahead, last, context), do: table_markup(s, ahead, last, context)

  defp table_markup(s, ahead, _last, context) when has(context, @table_open),
    do: table_cell_markup(s, ahead, context)

  defp table_markup(s, _ahead, _last, _context), do: text_char(s)

  defp done({result, s}), do: {:done, result, s}

  defp text_char(s) do
    s
    |> State.emit_char(State.current(s))
    |> State.forward()
  end

  # Whether only whitespace is between the position and the start of its line.
  defp leading_whitespace?(s), do: leading_whitespace?(s, 1)

  defp leading_whitespace?(s, n) do
    case State.behind(s, n) do
      char when line_start(char) -> true
      char -> State.space?(char) and leading_whitespace?(s, n + 1)
    end
  end

  # --- Templates and arguments --------------------------------------------------

  # `{{` opens a template, `{{{` an argument. Runs of more braces nest them,
  # innermost first: `{{{{{x}}}}}` is an argument in a template.
  defp template_or_argument(s) do
    braces =
      s
      |> State.rest()
      |> leading_count(?{)

    s =
      s
      |> State.forward(braces)
      |> State.push()

    nest_braces(s, braces, false)
  end

  defp nest_braces(s, 0, _has_content), do: finish_braces(s)
  defp nest_braces(s, 1, _has_content), do: braces_as_text(s, "{")

  defp nest_braces(s, 2, has_content) do
    case State.attempt(s, &template_body(&1, has_content)) do
      {:ok, s} -> finish_braces(s)
      {:failed, _context, s} -> braces_as_text(s, "{{")
    end
  end

  # Three or more braces: an argument if one closes, else a template.
  defp nest_braces(s, braces, has_content) do
    with {:failed, _context, s} <- State.attempt(s, &{argument_body(&1), 3}),
         {:failed, _context, s} <- State.attempt(s, &{template_body(&1, has_content), 2}) do
      braces_as_text(s, String.duplicate("{", braces))
    else
      {:ok, {s, closed}} -> nest_braces(s, braces - closed, true)
    end
  end

  defp finish_braces(s) do
    {tokens, below} = State.pop(s)

    below
    |> State.emit_all(tokens)
    |> clear_fail_next()
  end

  # A template or link noted a possible end at markup that turned out whole.
  defp clear_fail_next(s) do
    if has(State.context(s), @fail_next), do: State.toggle_flags(s, @fail_next), else: s
  end

  # The braces are text, followed by whatever was read inside them.
  defp braces_as_text(s, braces) do
    {tokens, below} = State.pop(s)

    below
    |> State.emit_text(braces)
    |> State.emit_all(tokens)
  end

  defp template_body(s, has_content) do
    context = if has_content, do: @template_name ||| @has_template, else: @template_name
    {tokens, read} = State.attempt_or_fail_from(s, s.pos, &parse(&1, context))

    read
    |> State.emit_first({:template_open, %{}})
    |> State.emit_all(tokens)
    |> State.emit({:template_close, %{}})
  end

  defp argument_body(s) do
    {tokens, read} = State.attempt_or_fail_from(s, s.pos, &parse(&1, @argument_name))

    read
    |> State.emit_first({:argument_open, %{}})
    |> State.emit_all(tokens)
    |> State.emit({:argument_close, %{}})
  end

  defp template_param(s) do
    separated =
      s
      |> end_template_part(State.context(s))
      |> State.add_flags(@template_param_key)
      |> State.emit({:template_param_separator, %{}})

    separated
    |> State.push(State.context(separated))
    |> State.forward()
  end

  # A `|` ends the template's name or a parameter.
  defp end_template_part(s, context) when has(context, @template_name) do
    require_template_name(s, context)
    State.toggle_flags(s, @template_name)
  end

  defp end_template_part(s, context) when has(context, @template_param_value),
    do: State.toggle_flags(s, @template_param_value)

  defp end_template_part(s, _context), do: emit_param_key(s)

  # A template's name holds text or a template.
  defp require_template_name(s, context) do
    if not has(context, @has_text ||| @has_template), do: State.fail(s)
  end

  # A parameter's key is read in a frame of its own.
  defp emit_param_key(s) do
    {key, below} = State.pop(s)
    State.emit_all(below, key)
  end

  defp template_param_value(s) do
    s
    |> emit_param_key()
    |> State.toggle_flags(@template_param_key)
    |> State.add_flags(@template_param_value)
    |> State.emit({:template_param_equals, %{}})
    |> State.forward()
  end

  defp template_end(s) do
    s
    |> close_template_part(State.context(s))
    |> State.forward(2)
    |> State.pop()
    |> done()
  end

  defp close_template_part(s, context) when has(context, @template_name) do
    require_template_name(s, context)
    s
  end

  defp close_template_part(s, context) when has(context, @template_param_key),
    do: emit_param_key(s)

  defp close_template_part(s, _context), do: s

  defp argument_separator(s) do
    s
    |> State.toggle_flags(@argument_name)
    |> State.add_flags(@argument_default)
    |> State.emit({:argument_separator, %{}})
    |> State.forward()
  end

  defp argument_end(s) do
    s
    |> State.forward(3)
    |> State.pop()
    |> done()
  end

  # --- Wikilinks ----------------------------------------------------------------

  # `[[` opens a wikilink, unless what follows is a URL: `[[http://x]]` is `[`
  # and an external link.
  defp wikilink(s) do
    start = s.pos
    after_brackets = State.forward(s, 2)

    case State.attempt(after_brackets, &external_link_body(&1, true)) do
      {:ok, {{link, _trailing}, linked}} ->
        url_in_double_brackets(linked, start, link)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start + 2)
        |> internal_link(start)
    end
  end

  # Inside an external link's title, `[[` before a URL is text.
  defp url_in_double_brackets(s, start, link) do
    if has(State.context(s), @ext_link_title) do
      s
      |> State.seek(start + 2)
      |> State.emit_text("[[")
    else
      s
      |> State.emit_text("[")
      |> emit_external_link(true, link)
    end
  end

  defp internal_link(s, start) do
    case State.attempt(s, &parse(&1, @wikilink_title)) do
      {:ok, {link, linked}} ->
        linked
        |> State.emit({:wikilink_open, %{}})
        |> State.emit_all(link)
        |> State.emit({:wikilink_close, %{}})

      {:failed, _context, failed} ->
        failed
        |> State.seek(start + 2)
        |> State.emit_text("[[")
    end
  end

  defp wikilink_separator(s) do
    s
    |> State.toggle_flags(@wikilink_title)
    |> State.add_flags(@wikilink_text)
    |> State.emit({:wikilink_separator, %{}})
    |> State.forward()
  end

  defp wikilink_end(s) do
    s
    |> State.forward(2)
    |> State.pop()
    |> done()
  end

  # --- External links -----------------------------------------------------------

  # `[URL title]`, or a free URL in running text, found at the `:` after its
  # scheme.
  defp external_link(s, brackets) do
    if has(State.context(s), @no_ext_links) or not nestable(s),
      do: not_a_link(s, brackets),
      else: read_external_link(s, brackets)
  end

  defp read_external_link(s, brackets) do
    start = s.pos
    after_opening = State.forward(s)

    case State.attempt(after_opening, &external_link_body(&1, brackets)) do
      {:ok, {{link, trailing}, linked}} ->
        linked
        |> emit_external_link(brackets, link)
        |> emit_nonempty_text(trailing)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> not_a_link(brackets)
    end
  end

  defp emit_external_link(s, brackets, link) do
    s
    |> take_back_scheme(brackets, link)
    |> State.emit({:external_link_open, %{brackets: brackets}})
    |> State.emit_all(link)
    |> State.emit({:external_link_close, %{}})
  end

  defp not_a_link(s, brackets) do
    if not brackets and has(State.context(s), @dl_term),
      do: definition_term_end(s),
      else: text_char(s)
  end

  # Reads the link's URL and title, returning `{{tokens, trailing}, s}`, with
  # the punctuation and space after a free link that is not part of it.
  defp external_link_body(s, brackets) do
    at_url = if brackets, do: bracketed_scheme(s), else: free_scheme(s)

    case State.current(at_url) do
      char when char in [:end, ?\n, ?\s, ?]] -> State.fail(at_url)
      ?[ when not brackets -> State.fail(at_url)
      _char -> url(at_url, %{brackets: brackets, tail: "", parens: false})
    end
  end

  defp bracketed_scheme(s) do
    pushed = State.push(s, @ext_link_uri)

    case State.ahead(pushed, 2) do
      [?/, ?/] -> read_slashes(pushed, true)
      _scheme -> named_scheme(pushed)
    end
  end

  defp named_scheme(s) do
    scheme =
      s
      |> State.rest()
      |> scheme_prefix()

    at_colon =
      s
      |> State.emit_text(scheme)
      |> State.seek(s.pos + byte_size(scheme))

    if State.current(at_colon) != ?:, do: State.fail(at_colon)

    after_colon =
      at_colon
      |> State.emit_text(":")
      |> State.forward()

    slashes = State.ahead(after_colon, 2) == [?/, ?/]
    after_scheme = read_slashes(after_colon, slashes)
    if not scheme?(scheme, slashes), do: State.fail(after_scheme)
    after_scheme
  end

  defp read_slashes(s, false), do: s

  defp read_slashes(s, true) do
    s
    |> State.emit_text("//")
    |> State.forward(2)
  end

  defp scheme_prefix(<<char, rest::binary>>) when char in @uri_scheme_chars,
    do: <<char>> <> scheme_prefix(rest)

  defp scheme_prefix(_text), do: ""

  # A free link's scheme was read as text before its `:`; it is the word that
  # ends the text read since the last token.
  defp free_scheme(s) do
    scheme =
      s
      |> State.pending_text()
      |> trailing_word()

    if scheme == :invalid, do: State.reject(s)

    slashes = State.ahead(s, 2) == [?/, ?/]
    if not scheme?(scheme, slashes), do: State.reject(s)

    s
    |> State.push(State.context(s) ||| @ext_link_uri)
    |> State.emit_text(scheme <> ":")
    |> read_slashes(slashes)
  end

  # The run of word characters at the end of the pending text, newest chunk
  # first, or `:invalid` when a word character in it cannot be in a scheme.
  defp trailing_word(chunks), do: trailing_word(chunks, [])

  defp trailing_word([], acc), do: List.to_string(acc)

  defp trailing_word([chunk | rest], acc) do
    reversed =
      chunk
      |> String.to_charlist()
      |> Enum.reverse()

    case word_chars(reversed, acc) do
      {:more, word} -> trailing_word(rest, word)
      {:word, word} -> List.to_string(word)
      :invalid -> :invalid
    end
  end

  defp word_chars([], acc), do: {:more, acc}

  defp word_chars([char | rest], acc) do
    cond do
      not word_char?(char) -> {:word, acc}
      char not in @uri_scheme_chars -> :invalid
      true -> word_chars(rest, [char | acc])
    end
  end

  defp word_char?(char), do: char == ?_ or String.match?(<<char::utf8>>, ~r/^[\p{L}\p{N}]$/u)

  defp scheme?(scheme, slashes) do
    case Map.fetch(@uri_schemes, String.downcase(scheme)) do
      {:ok, needs_slashes} -> slashes or not needs_slashes
      :error -> false
    end
  end

  # The scheme of a free link was emitted as text before the link; take it back.
  defp take_back_scheme(s, true, _link), do: s

  defp take_back_scheme(s, false, [url | _tokens]) do
    [scheme | _rest] = String.split(url, ":", parts: 2)
    State.put_pending_text(s, drop_trailing(State.pending_text(s), byte_size(scheme)))
  end

  defp drop_trailing(chunks, 0), do: chunks

  defp drop_trailing([chunk | rest], bytes) when bytes < byte_size(chunk),
    do: [binary_part(chunk, 0, byte_size(chunk) - bytes) | rest]

  defp drop_trailing([chunk | rest], bytes), do: drop_trailing(rest, bytes - byte_size(chunk))

  # Reads the URL. A free link holds trailing punctuation back in its `tail`,
  # as it is not part of the link unless more of the URL follows; an opening
  # parenthesis in the URL makes a closing one part of it.
  defp url(s, link) do
    [char, next | _rest] = State.ahead(s, 2)

    if nested_markup?(s, char, next) do
      s
      |> emit_nonempty_text(link.tail)
      |> nested_markup(char)
      |> url(%{link | tail: ""})
    else
      url_char(s, char, next, link)
    end
  end

  # Entities, comments and templates may sit inside a URL.
  defp nested_markup?(_s, ?&, _next), do: true
  defp nested_markup?(s, ?<, _next), do: State.ahead(s, 4) == [?<, ?!, ?-, ?-]
  defp nested_markup?(s, ?{, ?{), do: nestable(s)
  defp nested_markup?(_s, _char, _next), do: false

  defp nested_markup(s, ?&), do: entity(s)
  defp nested_markup(s, ?<), do: comment(s)
  defp nested_markup(s, ?{), do: template_or_argument(s)

  defp url_char(s, char, next, %{brackets: true}), do: bracketed_url(s, char, next)

  defp url_char(s, char, next, link) do
    cond do
      url_end?(s, char, next) ->
        end_free_link(s, char, link.tail)

      char == ?( and not link.parens ->
        s
        |> emit_nonempty_text(link.tail)
        |> text_char()
        |> url(%{link | tail: "", parens: true})

      char in @free_link_punctuation or (char == ?) and not link.parens) ->
        s
        |> State.forward()
        |> url(%{link | tail: link.tail <> <<char::utf8>>})

      true ->
        s
        |> emit_nonempty_text(link.tail)
        |> text_char()
        |> url(%{link | tail: ""})
    end
  end

  # A space after a free link is not part of it, but is read with it.
  defp end_free_link(s, ?\s, tail) do
    s
    |> State.forward()
    |> end_free_link(nil, tail <> " ")
  end

  defp end_free_link(s, _char, tail) do
    {tokens, below} = State.pop(s)
    {{tokens, tail}, below}
  end

  defp bracketed_url(s, char, _next) when char in [:end, ?\n], do: State.fail(s)

  defp bracketed_url(s, ?], _next) do
    {tokens, below} =
      s
      |> State.forward()
      |> State.pop()

    {{tokens, ""}, below}
  end

  defp bracketed_url(s, char, next) do
    if url_end?(s, char, next) do
      link_title(s, char)
    else
      s
      |> text_char()
      |> url(%{brackets: true, tail: "", parens: false})
    end
  end

  defp link_title(s, char) do
    {title, below} =
      s
      |> link_separator(char)
      |> State.toggle_flags(@ext_link_uri)
      |> State.add_flags(@ext_link_title)
      |> parse(0, push: false)

    {{title, ""}, below}
  end

  defp link_separator(s, ?\s) do
    s
    |> State.emit({:external_link_separator, %{}})
    |> State.forward()
  end

  defp link_separator(s, _char),
    do: State.emit(s, {:external_link_separator, %{suppress_space: true}})

  defp emit_nonempty_text(s, ""), do: s
  defp emit_nonempty_text(s, text), do: State.emit_text(s, text)

  defp url_end?(_s, char, _next) when char in [:end, ?\n, ?[, ?], ?<, ?>, ?", ?\s], do: true
  defp url_end?(_s, ?', ?'), do: true
  defp url_end?(s, char, next), do: url_end_in_context?(s, char, next, State.context(s))

  defp url_end_in_context?(_s, ?|, _next, context) when has(context, @template), do: true

  defp url_end_in_context?(_s, ?=, _next, context)
       when has(context, @template_param_key ||| @heading), do: true

  defp url_end_in_context?(_s, ?}, ?}, context) when has(context, @template), do: true

  defp url_end_in_context?(s, ?}, ?}, context) when has(context, @argument),
    do: State.peek(s, 2) == ?}

  defp url_end_in_context?(_s, _char, _next, _context), do: false

  # --- Headings -----------------------------------------------------------------

  # `== Title ==` at the start of a line. The level is the lesser of the runs
  # of `=` on either side, the rest of the longer run part of the title.
  defp heading(s) do
    start = s.pos

    equals =
      s
      |> State.rest()
      |> leading_count(?=)

    context = @heading_level_1 <<< min(equals - 1, 5)
    in_heading = State.forward(%{s | heading?: true}, equals)

    read =
      case State.attempt(in_heading, &parse(&1, context)) do
        {:ok, {{title, level}, parsed}} ->
          parsed
          |> State.emit({:heading_start, %{level: level}})
          |> emit_repeated("=", equals - level)
          |> State.emit_all(title)
          |> State.emit({:heading_end, %{}})

        {:failed, _context, failed} ->
          failed
          |> State.seek(start + equals)
          |> emit_repeated("=", equals)
      end

    %{read | heading?: false}
  end

  defp emit_repeated(s, _text, count) when count <= 0, do: s
  defp emit_repeated(s, text, count), do: State.emit_text(s, String.duplicate(text, count))

  defp leading_count(<<char, rest::binary>>, char), do: 1 + leading_count(rest, char)
  defp leading_count(_text, _char), do: 0

  # A run of `=` in a heading closes it, unless another closes it later.
  defp heading_end(s) do
    start = s.pos

    equals =
      s
      |> State.rest()
      |> leading_count(?=)

    level = closing_level(State.context(s), equals)
    after_equals = State.forward(s, equals)

    case State.attempt(after_equals, &parse(&1, State.context(&1))) do
      {:ok, {{title, later_level}, read}} ->
        {tokens, below} =
          read
          |> emit_repeated("=", equals)
          |> State.emit_all(title)
          |> State.pop()

        {:done, {tokens, later_level}, below}

      {:failed, _context, failed} ->
        {tokens, below} =
          failed
          |> emit_repeated("=", equals - level)
          |> State.seek(start + equals)
          |> State.pop()

        {:done, {tokens, level}, below}
    end
  end

  defp closing_level(context, equals), do: min(heading_level(context), min(equals, 6))

  defp heading_level(context), do: highest_bit(div(context, @heading_level_1)) + 1

  defp highest_bit(n) when n <= 1, do: 0
  defp highest_bit(n), do: 1 + highest_bit(n >>> 1)

  # --- HTML entities ------------------------------------------------------------

  # `&name;`, `&#nnnn;` or `&#xhhhh;`; anything else is text.
  defp entity(s) do
    start = s.pos

    case State.attempt(s, &entity_body/1) do
      {:ok, read} ->
        {tokens, below} = State.pop(read)
        State.emit_all(below, tokens)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> text_char()
    end
  end

  defp entity_body(s) do
    {kind, at_value} =
      s
      |> State.push(@html_entity)
      |> State.emit({:html_entity_start, %{}})
      |> State.forward()
      |> entity_kind()

    {at_end, value} = entity_value(at_value, kind, 0, "")
    if not valid_entity?(kind, value), do: State.fail(at_end)

    at_end
    |> State.emit(value)
    |> State.emit({:html_entity_end, %{}})
    |> State.forward()
  end

  defp entity_kind(s), do: entity_kind(s, State.ahead(s, 2))
  defp entity_kind(s, [:end, _next]), do: State.fail(s)

  defp entity_kind(s, [?#, x]) when x in [?x, ?X] do
    hexadecimal =
      s
      |> State.emit({:html_entity_numeric, %{}})
      |> State.forward()
      |> State.emit({:html_entity_hex, %{char: <<x>>}})
      |> State.forward()

    {:hexadecimal, hexadecimal}
  end

  defp entity_kind(s, [?#, :end]) do
    s
    |> State.forward()
    |> State.fail()
  end

  defp entity_kind(s, [?#, _digit]) do
    decimal =
      s
      |> State.emit({:html_entity_numeric, %{}})
      |> State.forward()

    {:decimal, decimal}
  end

  defp entity_kind(s, _name), do: {:named, s}

  defp valid_entity?(:named, value), do: Entities.codepoint(value) != nil
  defp valid_entity?(:decimal, value), do: String.to_integer(value) in 1..0x10FFFF
  defp valid_entity?(:hexadecimal, value), do: String.to_integer(value, 16) in 1..0x10FFFF

  # Reads the entity's name or number up to its `;`, numbers keeping their
  # leading zeros.
  defp entity_value(s, kind, zeros, value) do
    case State.current(s) do
      ?; when value == "" ->
        State.fail(s)

      ?; ->
        {s, String.duplicate("0", zeros) <> value}

      ?0 when value == "" and kind != :named ->
        s
        |> State.forward()
        |> entity_value(kind, zeros + 1, value)

      char ->
        if byte_size(value) >= @max_entity_length or marker(char) or not entity_char?(kind, char),
          do: State.fail(s)

        s
        |> State.forward()
        |> entity_value(kind, zeros, value <> <<char>>)
    end
  end

  defp entity_char?(:hexadecimal, char), do: char in ?0..?9 or char in ?a..?f or char in ?A..?F
  defp entity_char?(:decimal, char), do: char in ?0..?9
  defp entity_char?(:named, char), do: char in ?0..?9 or char in ?a..?z or char in ?A..?Z

  # --- Comments -----------------------------------------------------------------

  # `<!-- ... -->`; without its `-->`, `<!--` is text.
  defp comment(s) do
    start = s.pos

    opened =
      s
      |> State.forward(4)
      |> State.push()

    rest = State.rest(opened)

    case :binary.match(rest, "-->") do
      :nomatch ->
        opened
        |> State.drop()
        |> State.seek(start + 4)
        |> State.emit_text("<!--")

      {content_length, _match_length} ->
        {tokens, below} =
          opened
          |> emit_nonempty_text(binary_part(rest, 0, content_length))
          |> State.emit_first({:comment_start, %{}})
          |> State.emit({:comment_end, %{}})
          |> State.pop()

        below
        |> State.emit_all(tokens)
        |> State.seek(opened.pos + content_length + 3)
        |> clear_fail_next()
    end
  end

  # --- Tags ---------------------------------------------------------------------

  # `<name attributes>contents</name>` or `<name attributes/>`.
  defp tag(s) do
    start = s.pos
    after_bracket = State.forward(s)

    case State.attempt(after_bracket, &tag_body/1) do
      {:ok, {tokens, read}} ->
        State.emit_all(read, tokens)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> text_char()
    end
  end

  # `</br>` and the like: a void tag written as a closing tag.
  defp invalid_tag_start(s) do
    start = s.pos
    after_slash = State.forward(s, 2)

    case State.attempt(after_slash, &void_tag_body/1) do
      {:ok, {[{:tag_open_open, attrs} | tokens], read}} ->
        State.emit_all(read, [{:tag_open_open, Map.put(attrs, :invalid, true)} | tokens])

      {:failed, _context, failed} ->
        failed
        |> State.seek(start + 2)
        |> State.emit_text("</")
    end
  end

  defp void_tag_body(s) do
    if not void?(tag_name_ahead(s)), do: State.reject(s)
    tag_body(s)
  end

  defp tag_name_ahead(s) do
    s
    |> State.rest()
    |> String.to_charlist()
    |> Enum.take_while(&(not State.space?(&1) and not marker(&1)))
    |> List.to_string()
  end

  defp new_tag(context \\ @tag_name) do
    %{
      context: context,
      pad_first: "",
      pad_before_eq: "",
      pad_after_eq: "",
      quote: nil,
      quote_pos: 0
    }
  end

  defp tag_body(s) do
    s
    |> State.push(@tag_open)
    |> State.emit({:tag_open_open, %{}})
    |> tag_open(new_tag())
  end

  defp tag_open(s, tag) do
    [char, next | _rest] = State.ahead(s, 2)

    can_close? =
      not has(tag.context, @tag_quoted ||| @tag_name) or has(tag.context, @tag_note_space)

    tag_open_char(s, tag, char, next, can_close?)
  end

  defp tag_open_char(s, tag, :end, _next, _can_close?),
    do: unterminated_attributes(s, tag, &tag_open/2)

  defp tag_open_char(s, tag, ?>, _next, true) do
    s
    |> close_tag_open(tag, :tag_close_open)
    |> State.forward()
    |> State.put_context(@tag_body)
    |> tag_contents()
  end

  defp tag_open_char(s, tag, ?/, ?>, true) do
    s
    |> close_tag_open(tag, :tag_close_selfclose)
    |> State.forward(2)
    |> State.pop()
  end

  defp tag_open_char(s, tag, char, _next, _can_close?) do
    {read, read_tag} = tag_char(s, tag, char)
    tag_open(read, read_tag)
  end

  defp tag_contents(s) do
    name = tag_name(s)

    cond do
      void?(name) -> close_void_tag(s)
      parsed_contents?(name) -> parse(s, 0, push: false)
      true -> unparsed_contents(s)
    end
  end

  # The text ends inside a tag's attributes. An unclosed quote is text: the
  # attribute is read again from its quote.
  defp unterminated_attributes(s, tag, continue) do
    cond do
      has(State.context(s), @tag_attr) and has(tag.context, @tag_quoted) ->
        s
        |> reread_from_quote(tag)
        |> continue.(%{tag | context: @tag_attr_value})

      has(State.context(s), @tag_attr) ->
        s
        |> State.drop()
        |> State.fail()

      true ->
        State.fail(s)
    end
  end

  # The quotes were not a quoted value: the value is read again from the
  # opening quote, as text.
  defp reread_from_quote(s, tag) do
    s
    |> State.remember_failure()
    |> State.drop()
    |> State.seek(tag.quote_pos)
  end

  defp close_tag_open(s, tag, type) do
    {closed, closed_tag} = emit_pending_attribute(s, tag)
    State.emit(closed, {type, %{padding: closed_tag.pad_first}})
  end

  defp emit_pending_attribute(s, tag) do
    if has(tag.context, @tag_attr_name ||| @tag_attr_value),
      do: emit_attribute(s, tag),
      else: {s, tag}
  end

  # Reads one character of a tag's name and attributes.
  defp tag_char(s, tag, char) do
    context = tag.context

    cond do
      has(context, @tag_name) -> tag_name_char(s, tag, char)
      State.space?(char) -> tag_space(s, tag, char)
      has(context, @tag_note_space) -> after_attribute_char(s, tag)
      has(context, @tag_attr_ready) -> start_attribute(s, tag, char)
      has(context, @tag_attr_name) -> attribute_name_char(s, tag, char)
      true -> attribute_value_char(s, tag, char)
    end
  end

  defp tag_name_char(s, tag, char) do
    first? = not has(tag.context, @tag_note_space)

    cond do
      # Tags must start with text, not spaces.
      marker(char) or (State.space?(char) and first?) -> State.fail(s)
      first? -> {tag_text(s, char), %{tag | context: tag.context ||| @tag_note_space}}
      State.space?(char) -> tag_space(s, %{tag | context: @tag_attr_ready}, char)
      true -> {tag_text(s, char), tag}
    end
  end

  # Text right after a quoted value: the quotes were not a quoted value.
  defp after_attribute_char(s, tag) do
    if has(tag.context, @tag_quoted),
      do: {reread_from_quote(s, tag), %{tag | context: @tag_attr_value}},
      else: State.fail(s)
  end

  defp start_attribute(s, tag, char) do
    started =
      s
      |> State.push(@tag_attr)
      |> tag_text(char)

    {started, %{tag | context: @tag_attr_name}}
  end

  defp attribute_name_char(s, tag, ?=) do
    at_value =
      s
      |> State.emit({:tag_attr_equals, %{}})
      |> State.forward()

    {at_value, %{tag | context: @tag_attr_value ||| @tag_note_quote}}
  end

  defp attribute_name_char(s, tag, char) do
    if has(tag.context, @tag_note_equals) do
      # A space ended the name: this starts the next attribute.
      {emitted, next_tag} = emit_attribute(s, tag)
      start_attribute(emitted, next_tag, char)
    else
      {tag_text(s, char), tag}
    end
  end

  defp attribute_value_char(s, tag, char) do
    escaped? = State.behind(s, 1) == ?\\ and State.behind(s, 2) != ?\\

    cond do
      has(tag.context, @tag_note_quote) ->
        value_start_char(s, tag, char, escaped?)

      has(tag.context, @tag_quoted) and <<char::utf8>> == tag.quote and not escaped? ->
        {State.forward(s), %{tag | context: tag.context ||| @tag_note_space}}

      true ->
        {tag_text(s, char), tag}
    end
  end

  defp value_start_char(s, tag, char, false) when char in [?", ?'], do: open_quote(s, tag, char)

  defp value_start_char(s, tag, char, _escaped?),
    do: {tag_text(s, char), %{tag | context: bxor(tag.context, @tag_note_quote)}}

  defp open_quote(s, tag, char) do
    quoted = %{
      tag
      | context: bxor(tag.context, @tag_note_quote) ||| @tag_quoted,
        quote: <<char>>,
        quote_pos: s.pos
    }

    if State.failed_route?(s, State.context(s)) do
      # Already failed to read this as a quoted value: the quote is text.
      {s, %{quoted | context: @tag_attr_value}}
    else
      opened =
        s
        |> State.push(State.context(s))
        |> State.forward()

      {opened, quoted}
    end
  end

  defp tag_space(s, tag, char) do
    space = <<char::utf8>>
    {ended, ended_tag} = end_at_space(s, tag, space)
    take_space(ended, ended_tag, tag.context, space)
  end

  # A space ends an unquoted value, a quoted one after its closing quote, and
  # notes the end of a name.
  defp end_at_space(s, tag, space) do
    context = tag.context

    end_of_value? =
      has(context, @tag_attr_value) and not has(context, @tag_quoted ||| @tag_note_quote)

    after_quote? = has(context, @tag_quoted) and has(context, @tag_note_space)

    cond do
      end_of_value? or after_quote? ->
        {emitted, next_tag} = emit_attribute(s, tag)
        {emitted, %{next_tag | context: @tag_attr_ready}}

      has(context, @tag_note_space) ->
        {s, %{tag | context: @tag_attr_ready}}

      has(context, @tag_attr_name) ->
        {s,
         %{tag | context: context ||| @tag_note_equals, pad_before_eq: tag.pad_before_eq <> space}}

      true ->
        {s, tag}
    end
  end

  # The space is text in a quoted value, else padding.
  defp take_space(s, tag, old_context, space) do
    cond do
      has(old_context, @tag_quoted) and not has(old_context, @tag_note_space) ->
        spaced =
          s
          |> State.emit_text(space)
          |> State.forward()

        {spaced, tag}

      has(tag.context, @tag_attr_ready) ->
        {State.forward(s), %{tag | pad_first: tag.pad_first <> space}}

      has(tag.context, @tag_attr_value) ->
        {State.forward(s), %{tag | pad_after_eq: tag.pad_after_eq <> space}}

      true ->
        {State.forward(s), tag}
    end
  end

  # Text in a tag's name or attributes, which may hold templates, links and
  # tags.
  defp tag_text(s, char) do
    case State.ahead(s, 2) do
      _ahead when not marker(char) or not nestable(s) -> text_char(s)
      [?{, ?{] -> template_or_argument(s)
      [?[, ?[] -> wikilink(s)
      [?<, _next] -> tag(s)
      _ahead -> text_char(s)
    end
  end

  # Moves the attribute read so far into the tag's frame.
  defp emit_attribute(s, tag) do
    pads = Map.take(tag, [:pad_first, :pad_before_eq, :pad_after_eq])

    {attribute, below} =
      s
      |> close_quoted_value(tag)
      |> State.emit_first({:tag_attr_start, pads})
      |> State.pop()

    {State.emit_all(below, attribute),
     %{tag | pad_first: "", pad_before_eq: "", pad_after_eq: ""}}
  end

  # A quoted value is read in a frame of its own.
  defp close_quoted_value(s, tag) do
    if has(tag.context, @tag_quoted) do
      {value, below} =
        s
        |> State.emit_first({:tag_attr_quote, %{char: tag.quote}})
        |> State.pop()

      State.emit_all(below, value)
    else
      s
    end
  end

  # `</` in a tag's contents.
  defp closing_tag_open(s) do
    s
    |> State.emit({:tag_open_close, %{}})
    |> State.push(@tag_close)
    |> State.forward(2)
  end

  # `>` of a closing tag, which must name the tag it closes.
  defp closing_tag_close(s) do
    {closing, below} = State.pop(s)
    if not closes?(closing, tag_name(below)), do: State.fail(below)

    below
    |> State.emit_all(closing)
    |> State.emit({:tag_close_close, %{}})
    |> State.forward()
    |> State.pop()
    |> done()
  end

  defp closes?([name], tag) when is_binary(name), do: same_tag?(name, tag)
  defp closes?(_closing, _tag), do: false

  # The contents of a tag that holds no wikitext, read up to its closing tag.
  defp unparsed_contents(s), do: unparsed_contents(s, State.ahead(s, 2))

  defp unparsed_contents(s, [:end, _next]), do: State.fail(s)
  defp unparsed_contents(s, [?<, ?/]), do: unparsed_closing_tag(s)

  defp unparsed_contents(s, [?<, _next]) do
    s
    |> text_char()
    |> unparsed_contents()
  end

  defp unparsed_contents(s, [?&, _next]) do
    s
    |> entity()
    |> unparsed_contents()
  end

  defp unparsed_contents(s, _ahead) do
    text = State.text_run(s, &(&1 in [?<, ?&]))

    s
    |> State.emit_text(text)
    |> State.seek(s.pos + byte_size(text))
    |> unparsed_contents()
  end

  defp unparsed_closing_tag(s) do
    start = s.pos

    name =
      s
      |> State.forward(2)
      |> State.text_run(&(&1 in [?>, ?\n]))

    at_end = State.seek(s, start + 2 + byte_size(name))

    if State.current(at_end) == ?> and same_tag?(name, tag_name(at_end)) do
      at_end
      |> State.emit({:tag_open_close, %{}})
      |> State.emit_text(name)
      |> State.emit({:tag_close_close, %{}})
      |> State.forward()
      |> State.pop()
    else
      at_end
      |> State.seek(start + 2)
      |> State.emit_text("</")
      |> unparsed_contents()
    end
  end

  # A void tag's `>` closes it: `<br>` is `<br/>`.
  defp close_void_tag(s) do
    {{:tag_close_open, %{padding: padding}}, without_close} = State.take_last_token(s)

    without_close
    |> State.emit({:tag_close_selfclose, %{padding: padding, implicit: true}})
    |> State.pop()
  end

  # The text ends in a tag whose close MediaWiki supplies: the tag closes
  # where it opened, `<li>` becoming `<li>` with nothing inside.
  defp close_tag_implicitly(s) do
    s
    |> State.map_tokens(fn [open, name | tokens] ->
      [open, name | close_implicitly(tokens, 1)]
    end)
    |> State.pop()
  end

  defp close_implicitly([{:tag_open_open, _attrs} = token | rest], depth),
    do: [token | close_implicitly(rest, depth + 1)]

  defp close_implicitly([{:tag_close_open, %{padding: padding}} | rest], 1),
    do: [{:tag_close_selfclose, %{padding: padding, implicit: true}} | rest]

  defp close_implicitly([{type, _attrs} = token | rest], depth)
       when type in [:tag_close_open, :tag_close_selfclose],
       do: [token | close_implicitly(rest, depth - 1)]

  defp close_implicitly([token | rest], depth), do: [token | close_implicitly(rest, depth)]

  # The name of the tag of the current frame: its second token.
  defp tag_name(s) do
    case State.tokens(s) do
      [_open, name | _tokens] when is_binary(name) -> name
      _tokens -> nil
    end
  end

  defp same_tag?(a, b), do: normalize_tag(a) == normalize_tag(b)

  defp normalize_tag(name) do
    name
    |> Text.trim_trailing()
    |> String.downcase()
  end

  defp void?(name), do: is_binary(name) and String.downcase(name) in @void_tags

  defp optional_close?(name),
    do: is_binary(name) and String.downcase(name) in @optional_close_tags

  defp parsed_contents?(name), do: String.downcase(name) not in @unparsed_tags

  # --- Bold and italics ---------------------------------------------------------

  defp style_tag(s, tag, markup, body) do
    s
    |> State.emit({:tag_open_open, %{wiki_markup: markup}})
    |> State.emit_text(tag)
    |> State.emit({:tag_close_open, %{}})
    |> State.emit_all(body)
    |> State.emit({:tag_open_close, %{}})
    |> State.emit_text(tag)
    |> State.emit({:tag_close_close, %{}})
  end

  defp italics(s) do
    start = s.pos

    case State.attempt(s, &parse(&1, @style_italics)) do
      {:ok, {body, read}} ->
        style_tag(read, "i", "''", body)

      {:failed, context, failed} when has(context, @style_pass_again) ->
        failed
        |> State.seek(start)
        |> italics_second_pass(start)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> State.emit_text("''")
    end
  end

  # Bold inside was unclosed: read again, leaving the bold as text.
  defp italics_second_pass(s, start) do
    case State.attempt(s, &parse(&1, @style_italics ||| @style_second_pass)) do
      {:ok, {body, read}} ->
        style_tag(read, "i", "''", body)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> State.emit_text("''")
    end
  end

  # Returns `{s, done?}`: whether the enclosing italics are to end here.
  defp bold(s) do
    start = s.pos

    case State.attempt(s, &parse(&1, @style_bold)) do
      {:ok, {body, read}} ->
        {style_tag(read, "b", "'''", body), false}

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> unclosed_bold()
    end
  end

  defp unclosed_bold(s) do
    context = State.context(s)

    cond do
      has(context, @style_second_pass) ->
        {State.emit_text(s, "'"), true}

      has(context, @style_italics) ->
        marked =
          s
          |> State.add_flags(@style_pass_again)
          |> State.emit_text("'''")

        {marked, false}

      true ->
        as_italics =
          s
          |> State.emit_text("'")
          |> italics()

        {as_italics, false}
    end
  end

  # `'''''` opens bold and italics; whichever closes first is inside the other.
  defp bold_and_italics(s) do
    start = s.pos

    case State.attempt(s, &parse(&1, @style_bold)) do
      {:ok, {bold_body, read}} ->
        after_bold(read, bold_body)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> italics_first(start)
    end
  end

  defp after_bold(s, bold_body) do
    bold_end = s.pos

    case State.attempt(s, &parse(&1, @style_italics)) do
      {:ok, {rest, read}} ->
        nest_styles(read, {"b", "'''", bold_body}, rest, {"i", "''"})

      {:failed, _context, failed} ->
        failed
        |> State.seek(bold_end)
        |> State.emit_text("''")
        |> style_tag("b", "'''", bold_body)
    end
  end

  defp italics_first(s, start) do
    case State.attempt(s, &parse(&1, @style_italics)) do
      {:ok, {italics_body, read}} ->
        after_italics(read, italics_body)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> State.emit_text("'''''")
    end
  end

  defp after_italics(s, italics_body) do
    italics_end = s.pos

    case State.attempt(s, &parse(&1, @style_bold)) do
      {:ok, {rest, read}} ->
        nest_styles(read, {"i", "''", italics_body}, rest, {"b", "'''"})

      {:failed, _context, failed} ->
        failed
        |> State.seek(italics_end)
        |> State.emit_text("'''")
        |> style_tag("i", "''", italics_body)
    end
  end

  # The style that closed first, inside the other.
  defp nest_styles(s, {inner_tag, inner_markup, inner_body}, rest, {outer_tag, outer_markup}) do
    {body, below} =
      s
      |> State.push()
      |> style_tag(inner_tag, inner_markup, inner_body)
      |> State.emit_all(rest)
      |> State.pop()

    style_tag(below, outer_tag, outer_markup, body)
  end

  # A run of apostrophes: `''` italics, `'''` bold, `'''''` both; four is an
  # apostrophe and bold, more than five apostrophes and both.
  defp style(s) do
    ticks =
      s
      |> State.rest()
      |> leading_count(?')

    {at_style, style_ticks} =
      s
      |> State.forward(ticks)
      |> extra_ticks_as_text(ticks)

    style_markup(at_style, style_ticks, State.context(s))
  end

  defp extra_ticks_as_text(s, ticks) when ticks > 5, do: {emit_repeated(s, "'", ticks - 5), 5}
  defp extra_ticks_as_text(s, 4), do: {State.emit_text(s, "'"), 3}
  defp extra_ticks_as_text(s, ticks), do: {s, ticks}

  defp style_markup(s, ticks, context) do
    cond do
      closes_style?(ticks, context) -> close_style(s, ticks, context)
      not nestable(s) -> style_too_deep(s, ticks, context)
      ticks == 2 -> italics(s)
      ticks == 3 -> bold_or_end(s)
      true -> bold_and_italics(s)
    end
  end

  defp closes_style?(ticks, context) do
    (has(context, @style_italics) and ticks in [2, 5]) or
      (has(context, @style_bold) and ticks in [3, 5])
  end

  # Closes the current style; of five, the rest are read again.
  defp close_style(s, 5, context) do
    reread = if has(context, @style_italics), do: 3, else: 2
    done(State.pop(%{s | pos: s.pos - reread}))
  end

  defp close_style(s, _ticks, _context), do: done(State.pop(s))

  defp style_too_deep(s, 3, context) when has(context, @style_second_pass) do
    s
    |> State.emit_text("'")
    |> State.pop()
    |> done()
  end

  defp style_too_deep(s, ticks, context) do
    marked =
      if ticks == 3 and has(context, @style_italics),
        do: State.add_flags(s, @style_pass_again),
        else: s

    emit_repeated(marked, "'", ticks)
  end

  defp bold_or_end(s) do
    case bold(s) do
      {read, true} -> done(State.pop(read))
      {read, false} -> read
    end
  end

  # --- Lists and horizontal rules -----------------------------------------------

  # `*`, `#`, `;` and `:` at the start of a line, each a list item marker.
  defp list(s) do
    next =
      s
      |> list_marker()
      |> State.forward()

    if State.current(next) in @list_markers, do: list(next), else: next
  end

  defp list_marker(s) do
    marker = State.current(s)

    s
    |> note_definition_term(marker)
    |> State.emit({:tag_open_open, %{wiki_markup: <<marker>>}})
    |> State.emit_text(Map.fetch!(@list_tags, marker))
    |> State.emit({:tag_close_selfclose, %{}})
  end

  defp note_definition_term(s, ?;), do: State.add_flags(s, @dl_term)
  defp note_definition_term(s, _marker), do: s

  defp horizontal_rule(s) do
    dashes =
      s
      |> State.rest()
      |> leading_count(?-)

    s
    |> State.emit({:tag_open_open, %{wiki_markup: String.duplicate("-", dashes)}})
    |> State.emit_text("hr")
    |> State.emit({:tag_close_selfclose, %{}})
    |> State.forward(dashes)
  end

  # A `;` term ends at `:`, which starts its definition, or at the line's end.
  defp definition_term_end(s) do
    s
    |> State.toggle_flags(@dl_term)
    |> end_definition_term(State.current(s))
    |> State.forward()
  end

  defp end_definition_term(s, ?:), do: list_marker(s)
  defp end_definition_term(s, _newline), do: State.emit_text(s, "\n")

  # --- Tables -------------------------------------------------------------------

  defp table_tag(s, markup, tag, style, padding, separator, contents, closing_markup) do
    close_open =
      if separator, do: %{wiki_markup: separator, padding: padding}, else: %{padding: padding}

    s
    |> State.emit({:tag_open_open, %{wiki_markup: markup}})
    |> State.emit_text(tag)
    |> State.emit_all(style || [])
    |> State.emit({:tag_close_open, close_open})
    |> State.emit_all(contents)
    |> State.emit({:tag_open_close, %{wiki_markup: closing_markup}})
    |> State.emit_text(tag)
    |> State.emit({:tag_close_close, %{}})
  end

  # Reads attributes up to `end_char` in a frame of `context`, returning
  # `{s, padding}` with the whitespace after them, `end_char` itself unread.
  defp attributes_frame(s, context, end_char) do
    tag = new_tag(@tag_attr_ready)

    s
    |> State.push(context)
    |> table_attributes(tag, end_char)
  end

  defp table_attributes(s, tag, end_char) do
    char = State.current(s)
    can_close? = not has(tag.context, @tag_quoted) or has(tag.context, @tag_note_space)

    cond do
      char == end_char and can_close? ->
        end_attributes(s, tag, char)

      char in [:end, end_char] ->
        unterminated_attributes(s, tag, &table_attributes(&1, &2, end_char))

      true ->
        {read, read_tag} = tag_char(s, tag, char)
        table_attributes(read, read_tag, end_char)
    end
  end

  defp end_attributes(s, tag, char) do
    {ended, ended_tag} = emit_pending_attribute(s, tag)

    padding =
      if State.space?(char), do: ended_tag.pad_first <> <<char::utf8>>, else: ended_tag.pad_first

    {ended, padding}
  end

  # `{|` at the start of a line opens a table, its attributes on the same line.
  defp table(s) do
    start = s.pos
    after_opening = State.forward(s, 2)

    case State.attempt(after_opening, &attributes_frame(&1, @table_open, ?\n)) do
      {:ok, {read, padding}} ->
        table_contents(read, start, padding)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> text_char()
    end
  end

  defp table_contents(s, start, padding) do
    {style, below} = State.pop(s)
    at_contents = State.forward(below)
    restore_point = State.route(at_contents)

    case State.attempt(at_contents, &parse(&1, @table_open)) do
      {:ok, {contents, read}} ->
        table_tag(read, "{|", "table", style, padding, nil, contents, "|}")

      {:failed, _context, failed} ->
        failed
        |> unwind_to(restore_point)
        |> State.seek(start)
        |> text_char()
    end
  end

  defp unwind_to(s, route) do
    if State.route(s) == route do
      s
    else
      s
      |> State.remember_failure()
      |> State.drop()
      |> unwind_to(route)
    end
  end

  defp table_cell_markup(s, [?|, ?| | _rest], context) when has(context, @table_td_line),
    do: cell_or_end(s, "||", "td", @table_td_line, context)

  defp table_cell_markup(s, [?|, ?| | _rest], context) when has(context, @table_th_line),
    do: cell_or_end(s, "||", "th", @table_th_line, context)

  defp table_cell_markup(s, [?!, ?! | _rest], context) when has(context, @table_th_line),
    do: cell_or_end(s, "!!", "th", @table_th_line, context)

  defp table_cell_markup(s, [?| | _rest], context) when has(context, @table_cell_style),
    do: table_cell_end(s, true)

  # A line break ends the cells of its line.
  defp table_cell_markup(s, [?\n | _rest], context) when has(context, @table_cell_line) do
    s
    |> State.remove_flags(@table_cell_line)
    |> text_char()
  end

  defp table_cell_markup(s, [char, next | _rest], context) when char in [?|, ?!] do
    if leading_whitespace?(s),
      do: table_line_start(s, char, next, context),
      else: text_char(s)
  end

  defp table_cell_markup(s, _ahead, _context), do: text_char(s)

  defp cell_or_end(s, markup, tag, line_context, context) do
    if has(context, @table_cell_open),
      do: table_cell_end(s),
      else: table_cell(s, markup, tag, line_context)
  end

  defp table_line_start(s, _char, _next, context) when has(context, @table_cell_open),
    do: table_cell_end(s)

  defp table_line_start(s, ?|, next, context)
       when next in [?}, ?-] and has(context, @table_row_open), do: done(State.pop(s))

  defp table_line_start(s, ?|, ?}, _context) do
    s
    |> State.forward(2)
    |> State.pop()
    |> done()
  end

  defp table_line_start(s, ?|, ?-, _context), do: table_row(s)
  defp table_line_start(s, ?|, _next, _context), do: table_cell(s, "|", "td", @table_td_line)
  defp table_line_start(s, ?!, _next, _context), do: table_cell(s, "!", "th", @table_th_line)

  # `|-` opens a row, its attributes on the same line.
  defp table_row(s) do
    after_markup = State.forward(s, 2)

    if nestable(after_markup),
      do: read_table_row(after_markup),
      else: State.emit_text(after_markup, "|-")
  end

  defp read_table_row(s) do
    context = @table_open ||| @table_row_open
    {attributes, padding} = attributes_frame(s, context, ?\n)
    {style, below} = State.pop(attributes)

    {row, read} =
      below
      |> State.forward()
      |> parse(context)

    table_tag(read, "|-", "tr", style, padding, nil, row, "")
  end

  # A cell, `|` or `!` and `||` or `!!` on the same line; `attributes |` may
  # start it.
  defp table_cell(s, markup, tag, line_context) do
    after_markup = State.forward(s, byte_size(markup))

    if nestable(after_markup),
      do: read_table_cell(after_markup, {markup, tag}, line_context, State.context(s)),
      else: State.emit_text(after_markup, markup)
  end

  # Reads the cell as contents; if a `|` on its line ends attributes, reads it
  # again as attributes and contents.
  defp read_table_cell(s, {markup, tag}, line_context, outer_context) do
    cell_context = @table_open ||| @table_cell_open ||| line_context
    {contents, read} = parse(s, cell_context ||| @table_cell_style)
    read_context = State.context(read)
    restored = State.put_context(read, outer_context)

    cell =
      if has(read_context, @table_cell_style),
        do: styled_table_cell(restored, s.pos, cell_context, outer_context),
        else: %{
          s: restored,
          contents: contents,
          context: read_context,
          style: nil,
          padding: "",
          separator: nil
        }

    cell.s
    |> table_tag(markup, tag, cell.style, cell.padding, cell.separator, cell.contents, "")
    |> State.add_flags(band(cell.context, @table_th_line ||| @table_td_line))
  end

  defp styled_table_cell(s, contents_start, cell_context, outer_context) do
    {attributes, padding} =
      s
      |> State.seek(contents_start)
      |> attributes_frame(cell_context, ?|)

    {style, below} = State.pop(attributes)

    {contents, read} =
      below
      |> State.forward()
      |> parse(cell_context)

    %{
      s: State.put_context(read, outer_context),
      contents: contents,
      context: State.context(read),
      style: style,
      padding: padding,
      separator: "|"
    }
  end

  defp table_cell_end(s, style_ahead? \\ false) do
    s
    |> mark_cell_style(style_ahead?)
    |> State.pop(keep_context: true)
    |> done()
  end

  defp mark_cell_style(s, true), do: State.add_flags(s, @table_cell_style)
  defp mark_cell_style(s, false), do: State.remove_flags(s, @table_cell_style)
end
