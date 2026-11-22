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
  defguardp in_heading(state) when :erlang.map_get(:heading?, state)

  @spec tokenize(String.t(), keyword()) :: [term()]
  def tokenize(text, opts \\ []) do
    state = State.new(text, Keyword.get(opts, :skip_style_tags, false))

    case State.attempt(state, &parse(&1, 0)) do
      {:ok, {tokens, %State{frames: []}}} -> tokens
    end
  end

  # Reads with `context` until its construct ends, returning `{result, state}`:
  # the construct's tokens, or for a heading `{title_tokens, level}`.
  defp parse(state, context) do
    state
    |> State.push(context)
    |> read()
  end

  defp read(state) do
    char = State.current(state)

    if has(State.context(state), @unsafe) do
      state
      |> verify_safe(char)
      |> read_unsafe(char)
    else
      read_char(state, char)
    end
  end

  # Where some characters end the construct, each character is checked. Once
  # the first is read, the rest of a run of text needs no check unless the
  # context still has one pending (see `safety/3`).
  defp read_unsafe(state, char) when char in @markers or char == :end, do: read_char(state, char)

  defp read_unsafe(state, char) do
    first_read =
      state
      |> State.emit_char(char)
      |> State.forward()

    if run_safe?(State.context(first_read)),
      do:
        first_read
        |> take_plain_text()
        |> read(),
      else: read(first_read)
  end

  defp run_safe?(context) do
    not has(context, @fail_next ||| @fail_on_lbrace ||| @fail_on_rbrace) and
      (not has(context, @template_name) or
         (has(context, @has_text) and not has(context, @fail_on_text)))
  end

  defp read_char(state, :end), do: finish(state)

  defp read_char(state, char) when char in @markers do
    case markup(state, State.ahead(state, 4), State.behind(state, 1), State.context(state)) do
      {:done, result, done} -> {result, done}
      %State{} = next -> read(next)
    end
  end

  defp read_char(state, _char) do
    state
    |> take_plain_text()
    |> read()
  end

  # Takes the text up to the next character that may be markup.
  defp take_plain_text(state) do
    text = State.rest(state)
    State.take_text(state, binary_part(text, 0, plain_length(text, 0)))
  end

  defp plain_length(<<byte, rest::binary>>, length) when byte not in @markers,
    do: plain_length(rest, length + 1)

  defp plain_length(_text, length), do: length

  # The text ends inside the current construct.
  defp finish(state) do
    context = State.context(state)

    cond do
      not has(context, @unterminated_fails) ->
        State.pop(state)

      has(context, @tag_body) and optional_close?(tag_name(state)) ->
        close_tag_implicitly(state)

      true ->
        state
        |> drop_if(@table_cell_open)
        |> drop_if(@double)
        |> State.fail()
    end
  end

  # Drops the current frame when its context has one of `flags`: a frame read
  # on top of its construct's, which fails with it.
  defp drop_if(state, flags) do
    if has(State.context(state), flags), do: State.drop(state), else: state
  end

  # Fails the construct on a character it cannot hold, noting characters that
  # may end it on the next one.
  defp verify_safe(state, char) do
    case safety(state, char, State.context(state)) do
      :unsafe ->
        state
        |> drop_if(@double)
        |> State.fail()

      :safe ->
        state

      {:note, flags} ->
        State.add_flags(state, flags)

      {:toggle, flags} ->
        State.toggle_flags(state, flags)
    end
  end

  defp safety(_state, _char, context) when has(context, @fail_next), do: :unsafe

  defp safety(state, char, context) when has(context, @wikilink_title) do
    cond do
      char in [?], ?{] -> {:note, @fail_next}
      char in [?\n, ?[, ?}, ?>] -> :unsafe
      char == ?< and State.peek(state, 1) == ?! -> {:note, @fail_next}
      char == ?< -> :unsafe
      true -> :safe
    end
  end

  defp safety(_state, char, context) when has(context, @ext_link_title),
    do: if(char == ?\n, do: :unsafe, else: :safe)

  defp safety(state, char, context) when has(context, @template_name),
    do: template_name_safety(state, char, context)

  defp safety(_state, char, context) when has(context, @fail_on_equals),
    do: if(char == ?=, do: :unsafe, else: :safe)

  defp safety(state, char, context) when has(context, @fail_on_lbrace) do
    if char == ?{ or (State.behind(state, 1) == ?{ and State.behind(state, 2) == ?{) do
      if has(context, @template), do: {:note, @fail_on_equals}, else: {:note, @fail_next}
    else
      {:toggle, @fail_on_lbrace}
    end
  end

  defp safety(_state, char, context) when has(context, @fail_on_rbrace),
    do: if(char == ?}, do: {:note, @fail_next}, else: {:toggle, @fail_on_rbrace})

  defp safety(_state, ?{, _context), do: {:note, @fail_on_lbrace}
  defp safety(_state, ?}, _context), do: {:note, @fail_on_rbrace}
  defp safety(_state, _char, _context), do: :safe

  # A template's name: text, a `{{` inside it, or whitespace around it.
  defp template_name_safety(_state, ?{, _context), do: {:note, @has_template ||| @fail_next}
  defp template_name_safety(_state, ?}, _context), do: {:note, @fail_next}

  defp template_name_safety(state, ?<, _context),
    do: if(State.peek(state, 1) == ?!, do: {:note, @fail_next}, else: :unsafe)

  defp template_name_safety(_state, char, _context) when char in [?[, ?], ?>], do: :unsafe
  defp template_name_safety(_state, ?|, _context), do: :safe

  defp template_name_safety(_state, char, context) when has(context, @has_text),
    do: after_template_name_safety(char, context)

  defp template_name_safety(_state, char, _context),
    do: if(State.space?(char), do: :safe, else: {:note, @has_text})

  # After a line break, only whitespace may follow a template's name.
  defp after_template_name_safety(char, context) when has(context, @fail_on_text),
    do: if(State.space?(char), do: :safe, else: :unsafe)

  defp after_template_name_safety(?\n, _context), do: {:note, @fail_on_text}
  defp after_template_name_safety(_char, _context), do: :safe

  # --- Markup -------------------------------------------------------------------

  # Reads the markup at the position, given the next four characters, the one
  # before, and the context. Returns the state, or `{:done, result, state}` when the
  # markup ends the construct being read.
  defp markup(state, [?{, ?{ | _ahead], _last, _context) when nestable(state),
    do: template_or_argument(state)

  defp markup(state, [?{, ?{ | _ahead], _last, _context), do: text_char(state)

  defp markup(state, [?| | _ahead], _last, context) when has(context, @template),
    do: template_param(state)

  defp markup(state, [?=, next | _ahead], last, context) when has(context, @template_param_key) do
    if not in_heading(state) and line_start(last) and next == ?=,
      do: heading(state),
      else: template_param_value(state)
  end

  defp markup(state, [?}, ?} | _ahead], _last, context) when has(context, @template),
    do: template_end(state)

  defp markup(state, [?| | _ahead], _last, context) when has(context, @argument_name),
    do: argument_separator(state)

  defp markup(state, [?}, ?}, third | _ahead], _last, context) when has(context, @argument) do
    if third == ?}, do: argument_end(state), else: text_char(state)
  end

  defp markup(state, [?[, ?[ | _ahead], _last, context) when nestable(state) do
    if has(context, @no_wikilinks), do: text_char(state), else: wikilink(state)
  end

  defp markup(state, [?| | _ahead], _last, context) when has(context, @wikilink_title),
    do: wikilink_separator(state)

  defp markup(state, [?], ?] | _ahead], _last, context) when has(context, @wikilink),
    do: wikilink_end(state)

  defp markup(state, [?[ | _ahead], _last, _context), do: external_link(state, true)

  defp markup(state, [?: | _ahead], last, _context) when not marker(last),
    do: external_link(state, false)

  defp markup(state, [?] | _ahead], _last, context) when has(context, @ext_link_title) do
    state
    |> State.forward()
    |> State.pop()
    |> done()
  end

  defp markup(state, [?= | _ahead], last, context)
       when not in_heading(state) and not has(context, @template) do
    if line_start(last), do: heading(state), else: text_char(state)
  end

  defp markup(state, [?= | _ahead], _last, context) when has(context, @heading),
    do: heading_end(state)

  defp markup(state, [?\n | _ahead], _last, context) when has(context, @heading),
    do: State.fail(state)

  defp markup(state, [?& | _ahead], _last, _context), do: entity(state)

  defp markup(state, [?<, ?!, third, fourth], _last, _context) do
    if third == ?- and fourth == ?-, do: comment(state), else: text_char(state)
  end

  defp markup(state, [?<, ?/, third | _ahead], _last, context) when third != :end do
    if has(context, @tag_body), do: closing_tag_open(state), else: invalid_tag_start(state)
  end

  defp markup(state, [?< | _ahead], _last, context)
       when not has(context, @tag_close) and nestable(state), do: tag(state)

  defp markup(state, [?< | _ahead], _last, context) when not has(context, @tag_close),
    do: text_char(state)

  defp markup(state, [?> | _ahead], _last, context) when has(context, @tag_close),
    do: closing_tag_close(state)

  defp markup(%{skip_style_tags?: false} = state, [?', ?' | _ahead], _last, _context),
    do: style(state)

  defp markup(state, [char | _ahead], last, _context)
       when line_start(last) and char in @list_markers, do: list(state)

  defp markup(state, [?-, ?-, ?-, ?-], last, _context) when line_start(last),
    do: horizontal_rule(state)

  defp markup(state, [char | _ahead], _last, context)
       when char in [?\n, ?:] and has(context, @dl_term) do
    state = definition_term_end(state)
    if char == ?\n, do: State.remove_flags(state, @table_cell_line), else: state
  end

  defp markup(state, [?{, ?| | _ahead] = ahead, _last, context) do
    cond do
      not leading_whitespace?(state) -> table_markup(state, ahead, context)
      nestable(state) -> table(state)
      true -> text_char(state)
    end
  end

  defp markup(state, ahead, _last, context), do: table_markup(state, ahead, context)

  defp table_markup(state, ahead, context) when has(context, @table_open),
    do: table_cell_markup(state, ahead, context)

  defp table_markup(state, _ahead, _context), do: text_char(state)

  defp done({result, state}), do: {:done, result, state}

  defp text_char(state) do
    state
    |> State.emit_char(State.current(state))
    |> State.forward()
  end

  # Whether only whitespace is between the position and the start of its line.
  defp leading_whitespace?(state), do: leading_whitespace?(state, 1)

  defp leading_whitespace?(state, distance) do
    case State.behind(state, distance) do
      char when line_start(char) -> true
      char -> State.space?(char) and leading_whitespace?(state, distance + 1)
    end
  end

  # --- Templates and arguments --------------------------------------------------

  # `{{` opens a template, `{{{` an argument. Runs of more braces nest them,
  # innermost first: `{{{{{x}}}}}` is an argument in a template.
  defp template_or_argument(state) do
    braces =
      repeats(state, ?{)

    state =
      state
      |> State.forward(braces)
      |> State.push()

    nest_braces(state, braces, false)
  end

  defp nest_braces(state, 0, _has_content), do: finish_braces(state)
  defp nest_braces(state, 1, _has_content), do: braces_as_text(state, "{")

  defp nest_braces(state, 2, has_content) do
    case State.attempt(state, &template_body(&1, has_content)) do
      {:ok, state} -> finish_braces(state)
      {:failed, _context, state} -> braces_as_text(state, "{{")
    end
  end

  # Three or more braces: an argument if one closes, else a template.
  defp nest_braces(state, braces, has_content) do
    with {:failed, _context, state} <- State.attempt(state, &{argument_body(&1), 3}),
         {:failed, _context, state} <- State.attempt(state, &{template_body(&1, has_content), 2}) do
      braces_as_text(state, String.duplicate("{", braces))
    else
      {:ok, {state, closed}} -> nest_braces(state, braces - closed, true)
    end
  end

  defp finish_braces(state) do
    state
    |> State.merge_down()
    |> clear_fail_next()
  end

  # A template or link noted a possible end at markup that turned out whole.
  defp clear_fail_next(state) do
    if has(State.context(state), @fail_next),
      do: State.toggle_flags(state, @fail_next),
      else: state
  end

  # The braces are text, followed by whatever was read inside them.
  defp braces_as_text(state, braces) do
    {tokens, below} = State.pop(state)

    below
    |> State.emit_text(braces)
    |> State.emit_all(tokens)
  end

  defp template_body(state, has_content) do
    context = if has_content, do: @template_name ||| @has_template, else: @template_name
    brace_body(state, context, {:template_open, :template_close})
  end

  defp argument_body(state),
    do: brace_body(state, @argument_name, {:argument_open, :argument_close})

  # Reads a template's or argument's body, failing the braces around it with it.
  defp brace_body(state, context, {open, close}) do
    {tokens, read} = State.attempt_or_fail_from(state, state.pos, &parse(&1, context))

    read
    |> State.emit_first({open, %{}})
    |> State.emit_all(tokens)
    |> State.emit({close, %{}})
  end

  defp template_param(state) do
    separated =
      state
      |> end_template_part(State.context(state))
      |> State.add_flags(@template_param_key)
      |> State.emit({:template_param_separator, %{}})

    separated
    |> State.push(State.context(separated))
    |> State.forward()
  end

  # A `|` ends the template's name or a parameter.
  defp end_template_part(state, context) when has(context, @template_name) do
    require_template_name(state, context)
    State.toggle_flags(state, @template_name)
  end

  defp end_template_part(state, context) when has(context, @template_param_value),
    do: State.toggle_flags(state, @template_param_value)

  defp end_template_part(state, _context), do: emit_param_key(state)

  # A template's name holds text or a template.
  defp require_template_name(state, context) do
    if not has(context, @has_text ||| @has_template), do: State.fail(state)
  end

  # A parameter's key is read in a frame of its own.
  defp emit_param_key(state), do: State.merge_down(state)

  defp template_param_value(state) do
    state
    |> emit_param_key()
    |> State.toggle_flags(@template_param_key)
    |> State.add_flags(@template_param_value)
    |> State.emit({:template_param_equals, %{}})
    |> State.forward()
  end

  defp template_end(state) do
    state
    |> close_template_part(State.context(state))
    |> State.forward(2)
    |> State.pop()
    |> done()
  end

  defp close_template_part(state, context) when has(context, @template_name) do
    require_template_name(state, context)
    state
  end

  defp close_template_part(state, context) when has(context, @template_param_key),
    do: emit_param_key(state)

  defp close_template_part(state, _context), do: state

  defp argument_separator(state) do
    state
    |> State.toggle_flags(@argument_name)
    |> State.add_flags(@argument_default)
    |> State.emit({:argument_separator, %{}})
    |> State.forward()
  end

  defp argument_end(state) do
    state
    |> State.forward(3)
    |> State.pop()
    |> done()
  end

  # --- Wikilinks ----------------------------------------------------------------

  # `[[` opens a wikilink, unless what follows is a URL: `[[http://x]]` is `[`
  # and an external link.
  defp wikilink(state) do
    start = state.pos
    after_brackets = State.forward(state, 2)

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
  defp url_in_double_brackets(state, start, link) do
    if has(State.context(state), @ext_link_title) do
      state
      |> State.seek(start)
      |> State.take_text("[[")
    else
      state
      |> State.emit_text("[")
      |> emit_external_link(true, link)
    end
  end

  defp internal_link(state, start) do
    case State.attempt(state, &parse(&1, @wikilink_title)) do
      {:ok, {link, linked}} ->
        linked
        |> State.emit({:wikilink_open, %{}})
        |> State.emit_all(link)
        |> State.emit({:wikilink_close, %{}})

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> State.take_text("[[")
    end
  end

  defp wikilink_separator(state) do
    state
    |> State.toggle_flags(@wikilink_title)
    |> State.add_flags(@wikilink_text)
    |> State.emit({:wikilink_separator, %{}})
    |> State.forward()
  end

  defp wikilink_end(state) do
    state
    |> State.forward(2)
    |> State.pop()
    |> done()
  end

  # --- External links -----------------------------------------------------------

  # `[URL title]`, or a free URL in running text, found at the `:` after its
  # scheme.
  defp external_link(state, brackets) do
    if has(State.context(state), @no_ext_links) or not nestable(state),
      do: not_a_link(state, brackets),
      else: read_external_link(state, brackets)
  end

  defp read_external_link(state, brackets) do
    start = state.pos
    after_opening = State.forward(state)

    case State.attempt(after_opening, &external_link_body(&1, brackets)) do
      {:ok, {{link, trailing}, linked}} ->
        linked
        |> emit_external_link(brackets, link)
        |> State.emit_text(trailing)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> not_a_link(brackets)
    end
  end

  defp emit_external_link(state, brackets, link) do
    state
    |> take_back_scheme(brackets, link)
    |> State.emit({:external_link_open, %{brackets: brackets}})
    |> State.emit_all(link)
    |> State.emit({:external_link_close, %{}})
  end

  defp not_a_link(state, brackets) do
    if not brackets and has(State.context(state), @dl_term),
      do: definition_term_end(state),
      else: text_char(state)
  end

  # Reads the link's URL and title, returning `{{tokens, trailing}, state}`, with
  # the punctuation and space after a free link that is not part of it.
  defp external_link_body(state, brackets) do
    at_url = if brackets, do: bracketed_scheme(state), else: free_scheme(state)

    case State.current(at_url) do
      char when char in [:end, ?\n, ?\s, ?]] -> State.fail(at_url)
      ?[ when not brackets -> State.fail(at_url)
      _char -> url(at_url, %{brackets: brackets, tail: "", parens: false})
    end
  end

  defp bracketed_scheme(state) do
    pushed = State.push(state, @ext_link_uri)

    case State.ahead(pushed, 2) do
      [?/, ?/] -> read_slashes(pushed, true)
      _scheme -> named_scheme(pushed)
    end
  end

  defp named_scheme(state) do
    scheme = State.text_run(state, &(&1 not in @uri_scheme_chars))
    at_colon = State.take_text(state, scheme)

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

  defp read_slashes(state, false), do: state

  defp read_slashes(state, true) do
    state
    |> State.emit_text("//")
    |> State.forward(2)
  end

  # A free link's scheme was read as text before its `:`; it is the word that
  # ends the text read since the last token.
  defp free_scheme(state) do
    scheme =
      state
      |> State.pending_text()
      |> trailing_word()

    if scheme == :invalid, do: State.reject(state)

    slashes = State.ahead(state, 2) == [?/, ?/]
    if not scheme?(scheme, slashes), do: State.reject(state)

    state
    |> State.push(State.context(state) ||| @ext_link_uri)
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
  defp take_back_scheme(state, true, _link), do: state

  defp take_back_scheme(state, false, [url | _tokens]) do
    [scheme | _rest] = String.split(url, ":", parts: 2)
    State.put_pending_text(state, drop_trailing(State.pending_text(state), byte_size(scheme)))
  end

  defp drop_trailing(chunks, 0), do: chunks

  defp drop_trailing([chunk | rest], bytes) when bytes < byte_size(chunk),
    do: [binary_part(chunk, 0, byte_size(chunk) - bytes) | rest]

  defp drop_trailing([chunk | rest], bytes), do: drop_trailing(rest, bytes - byte_size(chunk))

  # Reads the URL. A free link holds trailing punctuation back in its `tail`,
  # as it is not part of the link unless more of the URL follows; an opening
  # parenthesis in the URL makes a closing one part of it.
  defp url(state, link) do
    [char, next | _rest] = State.ahead(state, 2)

    if nested_markup?(state, char, next) do
      state
      |> State.emit_text(link.tail)
      |> nested_markup(char)
      |> url(%{link | tail: ""})
    else
      url_char(state, char, next, link)
    end
  end

  # Entities, comments and templates may sit inside a URL.
  defp nested_markup?(_state, ?&, _next), do: true
  defp nested_markup?(state, ?<, _next), do: State.ahead(state, 4) == [?<, ?!, ?-, ?-]
  defp nested_markup?(state, ?{, ?{), do: nestable(state)
  defp nested_markup?(_state, _char, _next), do: false

  defp nested_markup(state, ?&), do: entity(state)
  defp nested_markup(state, ?<), do: comment(state)
  defp nested_markup(state, ?{), do: template_or_argument(state)

  defp url_char(state, char, next, %{brackets: true}), do: bracketed_url(state, char, next)

  defp url_char(state, char, next, link) do
    cond do
      url_end?(state, char, next) ->
        end_free_link(state, char, link.tail)

      char == ?( and not link.parens ->
        state
        |> State.emit_text(link.tail)
        |> text_char()
        |> url(%{link | tail: "", parens: true})

      char in @free_link_punctuation or (char == ?) and not link.parens) ->
        state
        |> State.forward()
        |> url(%{link | tail: link.tail <> <<char::utf8>>})

      true ->
        state
        |> State.emit_text(link.tail)
        |> text_char()
        |> url(%{link | tail: ""})
    end
  end

  # A space after a free link is not part of it, but is read with it.
  defp end_free_link(state, ?\s, tail) do
    state
    |> State.forward()
    |> end_free_link(nil, tail <> " ")
  end

  defp end_free_link(state, _char, tail) do
    {tokens, below} = State.pop(state)
    {{tokens, tail}, below}
  end

  defp bracketed_url(state, char, _next) when char in [:end, ?\n], do: State.fail(state)

  defp bracketed_url(state, ?], _next) do
    {tokens, below} =
      state
      |> State.forward()
      |> State.pop()

    {{tokens, ""}, below}
  end

  defp bracketed_url(state, char, next) do
    if url_end?(state, char, next) do
      link_title(state, char)
    else
      state
      |> text_char()
      |> url(%{brackets: true, tail: "", parens: false})
    end
  end

  defp link_title(state, char) do
    {title, below} =
      state
      |> link_separator(char)
      |> State.toggle_flags(@ext_link_uri)
      |> State.add_flags(@ext_link_title)
      |> read()

    {{title, ""}, below}
  end

  defp link_separator(state, ?\s) do
    state
    |> State.emit({:external_link_separator, %{}})
    |> State.forward()
  end

  defp link_separator(state, _char),
    do: State.emit(state, {:external_link_separator, %{suppress_space: true}})

  defp url_end?(_state, char, _next) when char in [:end, ?\n, ?[, ?], ?<, ?>, ?", ?\s], do: true
  defp url_end?(_state, ?', ?'), do: true

  defp url_end?(state, char, next),
    do: url_end_in_context?(state, char, next, State.context(state))

  defp url_end_in_context?(_state, ?|, _next, context) when has(context, @template), do: true

  defp url_end_in_context?(_state, ?=, _next, context)
       when has(context, @template_param_key ||| @heading), do: true

  defp url_end_in_context?(_state, ?}, ?}, context) when has(context, @template), do: true

  defp url_end_in_context?(state, ?}, ?}, context) when has(context, @argument),
    do: State.peek(state, 2) == ?}

  defp url_end_in_context?(_state, _char, _next, _context), do: false

  # --- Headings -----------------------------------------------------------------

  # `== Title ==` at the start of a line. The level is the lesser of the runs
  # of `=` on either side, the rest of the longer run part of the title.
  defp heading(state) do
    start = state.pos

    equals =
      repeats(state, ?=)

    context = @heading_level_1 <<< min(equals - 1, 5)
    in_heading = State.forward(%{state | heading?: true}, equals)

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

  defp emit_repeated(state, _text, count) when count <= 0, do: state

  defp emit_repeated(state, text, count),
    do: State.emit_text(state, String.duplicate(text, count))

  # How many times `char` repeats from the position on.
  defp repeats(state, char) do
    state
    |> State.rest()
    |> leading_count(char)
  end

  defp leading_count(<<char, rest::binary>>, char), do: 1 + leading_count(rest, char)
  defp leading_count(_text, _char), do: 0

  # A run of `=` in a heading closes it, unless another closes it later.
  defp heading_end(state) do
    start = state.pos

    equals =
      repeats(state, ?=)

    closing = closing_level(State.context(state), equals)
    after_equals = State.forward(state, equals)

    {read, level} =
      case State.attempt(after_equals, &parse(&1, State.context(&1))) do
        {:ok, {{title, later_level}, later}} ->
          {later
           |> emit_repeated("=", equals)
           |> State.emit_all(title), later_level}

        {:failed, _context, failed} ->
          {failed
           |> emit_repeated("=", equals - closing)
           |> State.seek(start + equals), closing}
      end

    {tokens, below} = State.pop(read)
    {:done, {tokens, level}, below}
  end

  defp closing_level(context, equals), do: min(heading_level(context), min(equals, 6))

  defp heading_level(context), do: highest_bit(div(band(context, @heading), @heading_level_1)) + 1

  defp highest_bit(flags) when flags <= 1, do: 0
  defp highest_bit(flags), do: 1 + highest_bit(flags >>> 1)

  # --- HTML entities ------------------------------------------------------------

  # `&name;`, `&#nnnn;` or `&#xhhhh;`; anything else is text.
  defp entity(state) do
    start = state.pos

    case State.attempt(state, &entity_body/1) do
      {:ok, read} ->
        State.merge_down(read)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> text_char()
    end
  end

  defp entity_body(state) do
    {kind, at_value} =
      state
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

  defp entity_kind(state), do: entity_kind(state, State.ahead(state, 2))
  defp entity_kind(state, [:end, _next]), do: State.fail(state)

  defp entity_kind(state, [?#, marker]) when marker in [?x, ?X] do
    hexadecimal =
      state
      |> State.emit({:html_entity_numeric, %{}})
      |> State.forward()
      |> State.emit({:html_entity_hex, %{char: <<marker>>}})
      |> State.forward()

    {:hexadecimal, hexadecimal}
  end

  defp entity_kind(state, [?#, :end]) do
    state
    |> State.forward()
    |> State.fail()
  end

  defp entity_kind(state, [?#, _digit]) do
    decimal =
      state
      |> State.emit({:html_entity_numeric, %{}})
      |> State.forward()

    {:decimal, decimal}
  end

  defp entity_kind(state, _name), do: {:named, state}

  defp valid_entity?(:named, value), do: Entities.codepoint(value) != nil
  defp valid_entity?(:decimal, value), do: String.to_integer(value) in 1..0x10FFFF
  defp valid_entity?(:hexadecimal, value), do: String.to_integer(value, 16) in 1..0x10FFFF

  # Reads the entity's name or number up to its `;`, numbers keeping their
  # leading zeros.
  defp entity_value(state, kind, zeros, value) do
    case State.current(state) do
      ?; when value == "" ->
        State.fail(state)

      ?; ->
        {state, String.duplicate("0", zeros) <> value}

      ?0 when value == "" and kind != :named ->
        state
        |> State.forward()
        |> entity_value(kind, zeros + 1, value)

      char ->
        if byte_size(value) >= @max_entity_length or marker(char) or not entity_char?(kind, char),
          do: State.fail(state)

        state
        |> State.forward()
        |> entity_value(kind, zeros, value <> <<char>>)
    end
  end

  defp entity_char?(:hexadecimal, char), do: char in ?0..?9 or char in ?a..?f or char in ?A..?F
  defp entity_char?(:decimal, char), do: char in ?0..?9
  defp entity_char?(:named, char), do: char in ?0..?9 or char in ?a..?z or char in ?A..?Z

  # --- Comments -----------------------------------------------------------------

  # `<!-- ... -->`; without its `-->`, `<!--` is text.
  defp comment(state) do
    start = state.pos

    opened =
      state
      |> State.forward(4)
      |> State.push()

    rest = State.rest(opened)

    case :binary.match(rest, "-->") do
      :nomatch ->
        opened
        |> State.drop()
        |> State.seek(start)
        |> State.take_text("<!--")

      {content_length, _match_length} ->
        opened
        |> State.emit_text(binary_part(rest, 0, content_length))
        |> State.emit_first({:comment_start, %{}})
        |> State.emit({:comment_end, %{}})
        |> State.merge_down()
        |> State.seek(opened.pos + content_length + 3)
        |> clear_fail_next()
    end
  end

  # --- Tags ---------------------------------------------------------------------

  # `<name attributes>contents</name>` or `<name attributes/>`.
  defp tag(state) do
    start = state.pos
    after_bracket = State.forward(state)

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
  defp invalid_tag_start(state) do
    start = state.pos
    after_slash = State.forward(state, 2)

    case State.attempt(after_slash, &void_tag_body/1) do
      {:ok, {[{:tag_open_open, attrs} | tokens], read}} ->
        State.emit_all(read, [{:tag_open_open, Map.put(attrs, :invalid, true)} | tokens])

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> State.take_text("</")
    end
  end

  defp void_tag_body(state) do
    if not void?(tag_name_ahead(state)), do: State.reject(state)
    tag_body(state)
  end

  defp tag_name_ahead(state) do
    text = State.rest(state)
    binary_part(text, 0, byte_size(text) - byte_size(after_tag_name(text)))
  end

  defp after_tag_name(<<char::utf8, rest::binary>> = text) do
    if marker(char) or State.space?(char), do: text, else: after_tag_name(rest)
  end

  defp after_tag_name(<<>>), do: <<>>

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

  defp tag_body(state) do
    state
    |> State.push(@tag_open)
    |> State.emit({:tag_open_open, %{}})
    |> tag_open(new_tag())
  end

  defp tag_open(state, tag) do
    [char, next | _rest] = State.ahead(state, 2)

    can_close? =
      not has(tag.context, @tag_quoted ||| @tag_name) or has(tag.context, @tag_note_space)

    tag_open_char(state, tag, char, next, can_close?)
  end

  defp tag_open_char(state, tag, :end, _next, _can_close?),
    do: unterminated_attributes(state, tag, &tag_open/2)

  defp tag_open_char(state, tag, ?>, _next, true) do
    state
    |> close_tag_open(tag, :tag_close_open)
    |> State.forward()
    |> State.put_context(@tag_body)
    |> tag_contents()
  end

  defp tag_open_char(state, tag, ?/, ?>, true) do
    state
    |> close_tag_open(tag, :tag_close_selfclose)
    |> State.forward(2)
    |> State.pop()
  end

  defp tag_open_char(state, tag, char, _next, _can_close?) do
    {read, read_tag} = tag_char(state, tag, char)
    tag_open(read, read_tag)
  end

  defp tag_contents(state) do
    name = tag_name(state)

    cond do
      void?(name) -> close_void_tag(state)
      parsed_contents?(name) -> read(state)
      true -> unparsed_contents(state)
    end
  end

  # The text ends inside a tag's attributes. An unclosed quote is text: the
  # attribute is read again from its quote.
  defp unterminated_attributes(state, tag, continue) do
    cond do
      has(State.context(state), @tag_attr) and has(tag.context, @tag_quoted) ->
        state
        |> reread_from_quote(tag)
        |> continue.(%{tag | context: @tag_attr_value})

      has(State.context(state), @tag_attr) ->
        state
        |> State.drop()
        |> State.fail()

      true ->
        State.fail(state)
    end
  end

  # The quotes were not a quoted value: the value is read again from the
  # opening quote, as text.
  defp reread_from_quote(state, tag) do
    state
    |> State.abandon()
    |> State.seek(tag.quote_pos)
  end

  defp close_tag_open(state, tag, type) do
    {closed, closed_tag} = emit_pending_attribute(state, tag)
    State.emit(closed, {type, %{padding: closed_tag.pad_first}})
  end

  defp emit_pending_attribute(state, tag) do
    if has(tag.context, @tag_attr_name ||| @tag_attr_value),
      do: emit_attribute(state, tag),
      else: {state, tag}
  end

  # Reads one character of a tag's name and attributes.
  defp tag_char(state, tag, char) do
    context = tag.context

    cond do
      has(context, @tag_name) -> tag_name_char(state, tag, char)
      State.space?(char) -> tag_space(state, tag, char)
      has(context, @tag_note_space) -> after_attribute_char(state, tag)
      has(context, @tag_attr_ready) -> start_attribute(state, tag, char)
      has(context, @tag_attr_name) -> attribute_name_char(state, tag, char)
      true -> attribute_value_char(state, tag, char)
    end
  end

  defp tag_name_char(state, tag, char) do
    first? = not has(tag.context, @tag_note_space)

    cond do
      # Tags must start with text, not spaces.
      marker(char) or (State.space?(char) and first?) -> State.fail(state)
      first? -> {tag_text(state, char), %{tag | context: tag.context ||| @tag_note_space}}
      State.space?(char) -> tag_space(state, %{tag | context: @tag_attr_ready}, char)
      true -> {tag_text(state, char), tag}
    end
  end

  # Text right after a quoted value: the quotes were not a quoted value.
  defp after_attribute_char(state, tag) do
    if has(tag.context, @tag_quoted),
      do: {reread_from_quote(state, tag), %{tag | context: @tag_attr_value}},
      else: State.fail(state)
  end

  defp start_attribute(state, tag, char) do
    started =
      state
      |> State.push(@tag_attr)
      |> tag_text(char)

    {started, %{tag | context: @tag_attr_name}}
  end

  defp attribute_name_char(state, tag, ?=) do
    at_value =
      state
      |> State.emit({:tag_attr_equals, %{}})
      |> State.forward()

    {at_value, %{tag | context: @tag_attr_value ||| @tag_note_quote}}
  end

  defp attribute_name_char(state, tag, char) do
    if has(tag.context, @tag_note_equals) do
      # A space ended the name: this starts the next attribute.
      {emitted, next_tag} = emit_attribute(state, tag)
      start_attribute(emitted, next_tag, char)
    else
      {tag_text(state, char), tag}
    end
  end

  defp attribute_value_char(state, tag, char) do
    escaped? = State.behind(state, 1) == ?\\ and State.behind(state, 2) != ?\\

    cond do
      has(tag.context, @tag_note_quote) ->
        value_start_char(state, tag, char, escaped?)

      has(tag.context, @tag_quoted) and <<char::utf8>> == tag.quote and not escaped? ->
        {State.forward(state), %{tag | context: tag.context ||| @tag_note_space}}

      true ->
        {tag_text(state, char), tag}
    end
  end

  defp value_start_char(state, tag, char, false) when char in [?", ?'],
    do: open_quote(state, tag, char)

  defp value_start_char(state, tag, char, _escaped?),
    do: {tag_text(state, char), %{tag | context: bxor(tag.context, @tag_note_quote)}}

  defp open_quote(state, tag, char) do
    quoted = %{
      tag
      | context: bxor(tag.context, @tag_note_quote) ||| @tag_quoted,
        quote: <<char>>,
        quote_pos: state.pos
    }

    if State.failed_route?(state, State.context(state)) do
      # Already failed to read this as a quoted value: the quote is text.
      {state, %{quoted | context: @tag_attr_value}}
    else
      opened =
        state
        |> State.push(State.context(state))
        |> State.forward()

      {opened, quoted}
    end
  end

  defp tag_space(state, tag, char) do
    space = <<char::utf8>>
    {ended, ended_tag} = end_at_space(state, tag, space)
    take_space(ended, ended_tag, tag.context, space)
  end

  # A space ends an unquoted value, a quoted one after its closing quote, and
  # notes the end of a name.
  defp end_at_space(state, tag, space) do
    context = tag.context

    end_of_value? =
      has(context, @tag_attr_value) and not has(context, @tag_quoted ||| @tag_note_quote)

    after_quote? = has(context, @tag_quoted) and has(context, @tag_note_space)

    cond do
      end_of_value? or after_quote? ->
        {emitted, next_tag} = emit_attribute(state, tag)
        {emitted, %{next_tag | context: @tag_attr_ready}}

      has(context, @tag_note_space) ->
        {state, %{tag | context: @tag_attr_ready}}

      has(context, @tag_attr_name) ->
        {state,
         %{tag | context: context ||| @tag_note_equals, pad_before_eq: tag.pad_before_eq <> space}}

      true ->
        {state, tag}
    end
  end

  # The space is text in a quoted value, else padding.
  defp take_space(state, tag, old_context, space) do
    cond do
      has(old_context, @tag_quoted) and not has(old_context, @tag_note_space) ->
        spaced =
          state
          |> State.emit_text(space)
          |> State.forward()

        {spaced, tag}

      has(tag.context, @tag_attr_ready) ->
        {State.forward(state), %{tag | pad_first: tag.pad_first <> space}}

      has(tag.context, @tag_attr_value) ->
        {State.forward(state), %{tag | pad_after_eq: tag.pad_after_eq <> space}}

      true ->
        {State.forward(state), tag}
    end
  end

  # Text in a tag's name or attributes, which may hold templates, links and
  # tags.
  defp tag_text(state, char) do
    case State.ahead(state, 2) do
      _ahead when not marker(char) or not nestable(state) -> text_char(state)
      [?{, ?{] -> template_or_argument(state)
      [?[, ?[] -> wikilink(state)
      [?<, _next] -> tag(state)
      _ahead -> text_char(state)
    end
  end

  # Moves the attribute read so far into the tag's frame.
  defp emit_attribute(state, tag) do
    pads = Map.take(tag, [:pad_first, :pad_before_eq, :pad_after_eq])

    emitted =
      state
      |> close_quoted_value(tag)
      |> State.emit_first({:tag_attr_start, pads})
      |> State.merge_down()

    {emitted, %{tag | pad_first: "", pad_before_eq: "", pad_after_eq: ""}}
  end

  # A quoted value is read in a frame of its own.
  defp close_quoted_value(state, tag) do
    if has(tag.context, @tag_quoted) do
      state
      |> State.emit_first({:tag_attr_quote, %{char: tag.quote}})
      |> State.merge_down()
    else
      state
    end
  end

  # `</` in a tag's contents.
  defp closing_tag_open(state) do
    state
    |> State.emit({:tag_open_close, %{}})
    |> State.push(@tag_close)
    |> State.forward(2)
  end

  # `>` of a closing tag, which must name the tag it closes.
  defp closing_tag_close(state) do
    {closing, below} = State.pop(state)
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
  defp unparsed_contents(state), do: unparsed_contents(state, State.ahead(state, 2))

  defp unparsed_contents(state, [:end, _next]), do: State.fail(state)
  defp unparsed_contents(state, [?<, ?/]), do: unparsed_closing_tag(state)

  defp unparsed_contents(state, [?<, _next]) do
    state
    |> text_char()
    |> unparsed_contents()
  end

  defp unparsed_contents(state, [?&, _next]) do
    state
    |> entity()
    |> unparsed_contents()
  end

  defp unparsed_contents(state, _ahead) do
    state
    |> State.take_text(State.text_run(state, &(&1 in [?<, ?&])))
    |> unparsed_contents()
  end

  defp unparsed_closing_tag(state) do
    start = state.pos

    name =
      state
      |> State.forward(2)
      |> State.text_run(&(&1 in [?>, ?\n]))

    at_end = State.seek(state, start + 2 + byte_size(name))

    if State.current(at_end) == ?> and same_tag?(name, tag_name(at_end)) do
      at_end
      |> State.emit({:tag_open_close, %{}})
      |> State.emit_text(name)
      |> State.emit({:tag_close_close, %{}})
      |> State.forward()
      |> State.pop()
    else
      at_end
      |> State.seek(start)
      |> State.take_text("</")
      |> unparsed_contents()
    end
  end

  # A void tag's `>` closes it: `<br>` is `<br/>`.
  defp close_void_tag(state) do
    {{:tag_close_open, %{padding: padding}}, without_close} = State.take_last_token(state)

    without_close
    |> State.emit({:tag_close_selfclose, %{padding: padding, implicit: true}})
    |> State.pop()
  end

  # The text ends in a tag whose close MediaWiki supplies: the tag closes
  # where it opened, `<li>` becoming `<li>` with nothing inside.
  defp close_tag_implicitly(state) do
    state
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
  defp tag_name(state) do
    case State.tokens(state) do
      [_open, name | _tokens] when is_binary(name) -> name
      _tokens -> nil
    end
  end

  defp same_tag?(name, other), do: normalize_tag(name) == normalize_tag(other)

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

  defp style_tag(state, tag, markup, body) do
    state
    |> State.emit({:tag_open_open, %{wiki_markup: markup}})
    |> State.emit_text(tag)
    |> State.emit({:tag_close_open, %{}})
    |> State.emit_all(body)
    |> State.emit({:tag_open_close, %{}})
    |> State.emit_text(tag)
    |> State.emit({:tag_close_close, %{}})
  end

  # Italics with a bold inside left unclosed are read once more, the bold as
  # text.
  defp italics(state, context \\ @style_italics) do
    start = state.pos

    case State.attempt(state, &parse(&1, context)) do
      {:ok, {body, read}} ->
        style_tag(read, "i", "''", body)

      {:failed, failed_context, failed}
      when has(failed_context, @style_pass_again) and context == @style_italics ->
        failed
        |> State.seek(start)
        |> italics(@style_italics ||| @style_second_pass)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> State.emit_text("''")
    end
  end

  # Returns `{state, done?}`: whether the enclosing italics are to end here.
  defp bold(state) do
    start = state.pos

    case State.attempt(state, &parse(&1, @style_bold)) do
      {:ok, {body, read}} ->
        {style_tag(read, "b", "'''", body), false}

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> unclosed_bold()
    end
  end

  defp unclosed_bold(state) do
    context = State.context(state)

    cond do
      has(context, @style_second_pass) ->
        {State.emit_text(state, "'"), true}

      has(context, @style_italics) ->
        marked =
          state
          |> State.add_flags(@style_pass_again)
          |> State.emit_text("'''")

        {marked, false}

      true ->
        as_italics =
          state
          |> State.emit_text("'")
          |> italics()

        {as_italics, false}
    end
  end

  # `'''''` opens bold and italics; whichever closes first is inside the other.
  defp bold_and_italics(state) do
    start = state.pos

    case State.attempt(state, &parse(&1, @style_bold)) do
      {:ok, {bold_body, read}} ->
        after_first_style(read, {"b", "'''", bold_body}, {"i", "''", @style_italics})

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> italics_first(start)
    end
  end

  defp italics_first(state, start) do
    case State.attempt(state, &parse(&1, @style_italics)) do
      {:ok, {italics_body, read}} ->
        after_first_style(read, {"i", "''", italics_body}, {"b", "'''", @style_bold})

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> State.emit_text("'''''")
    end
  end

  # The style that closed first is read; the other either closes around it or
  # is text.
  defp after_first_style(state, {tag, markup, body} = first, {other_tag, other_markup, context}) do
    first_end = state.pos

    case State.attempt(state, &parse(&1, context)) do
      {:ok, {rest, read}} ->
        nest_styles(read, first, rest, {other_tag, other_markup})

      {:failed, _context, failed} ->
        failed
        |> State.seek(first_end)
        |> State.emit_text(other_markup)
        |> style_tag(tag, markup, body)
    end
  end

  # The style that closed first, inside the other.
  defp nest_styles(state, {inner_tag, inner_markup, inner_body}, rest, {outer_tag, outer_markup}) do
    {body, below} =
      state
      |> State.push()
      |> style_tag(inner_tag, inner_markup, inner_body)
      |> State.emit_all(rest)
      |> State.pop()

    style_tag(below, outer_tag, outer_markup, body)
  end

  # A run of apostrophes: `''` italics, `'''` bold, `'''''` both; four is an
  # apostrophe and bold, more than five apostrophes and both.
  defp style(state) do
    ticks =
      repeats(state, ?')

    {at_style, style_ticks} =
      state
      |> State.forward(ticks)
      |> extra_ticks_as_text(ticks)

    style_markup(at_style, style_ticks, State.context(state))
  end

  defp extra_ticks_as_text(state, ticks) when ticks > 5,
    do: {emit_repeated(state, "'", ticks - 5), 5}

  defp extra_ticks_as_text(state, 4), do: {State.emit_text(state, "'"), 3}
  defp extra_ticks_as_text(state, ticks), do: {state, ticks}

  defp style_markup(state, ticks, context) do
    cond do
      closes_style?(ticks, context) -> close_style(state, ticks, context)
      not nestable(state) -> style_too_deep(state, ticks, context)
      ticks == 2 -> italics(state)
      ticks == 3 -> bold_or_end(state)
      true -> bold_and_italics(state)
    end
  end

  defp closes_style?(ticks, context) do
    (has(context, @style_italics) and ticks in [2, 5]) or
      (has(context, @style_bold) and ticks in [3, 5])
  end

  # Closes the current style; of five, the rest are read again.
  defp close_style(state, 5, context) do
    reread = if has(context, @style_italics), do: 3, else: 2
    done(State.pop(%{state | pos: state.pos - reread}))
  end

  defp close_style(state, _ticks, _context), do: done(State.pop(state))

  defp style_too_deep(state, 3, context) when has(context, @style_second_pass) do
    state
    |> State.emit_text("'")
    |> State.pop()
    |> done()
  end

  defp style_too_deep(state, ticks, context) do
    marked =
      if ticks == 3 and has(context, @style_italics),
        do: State.add_flags(state, @style_pass_again),
        else: state

    emit_repeated(marked, "'", ticks)
  end

  defp bold_or_end(state) do
    case bold(state) do
      {read, true} -> done(State.pop(read))
      {read, false} -> read
    end
  end

  # --- Lists and horizontal rules -----------------------------------------------

  # `*`, `#`, `;` and `:` at the start of a line, each a list item marker.
  defp list(state) do
    next =
      state
      |> list_marker()
      |> State.forward()

    if State.current(next) in @list_markers, do: list(next), else: next
  end

  defp list_marker(state) do
    marker = State.current(state)

    state
    |> note_definition_term(marker)
    |> State.emit({:tag_open_open, %{wiki_markup: <<marker>>}})
    |> State.emit_text(Map.fetch!(@list_tags, marker))
    |> State.emit({:tag_close_selfclose, %{}})
  end

  defp note_definition_term(state, ?;), do: State.add_flags(state, @dl_term)
  defp note_definition_term(state, _marker), do: state

  defp horizontal_rule(state) do
    dashes =
      repeats(state, ?-)

    state
    |> State.emit({:tag_open_open, %{wiki_markup: String.duplicate("-", dashes)}})
    |> State.emit_text("hr")
    |> State.emit({:tag_close_selfclose, %{}})
    |> State.forward(dashes)
  end

  # A `;` term ends at `:`, which starts its definition, or at the line's end.
  defp definition_term_end(state) do
    state
    |> State.toggle_flags(@dl_term)
    |> end_definition_term(State.current(state))
    |> State.forward()
  end

  defp end_definition_term(state, ?:), do: list_marker(state)
  defp end_definition_term(state, _newline), do: State.emit_text(state, "\n")

  # --- Tables -------------------------------------------------------------------

  # Emits a table, row or cell from its markup, its tag, and `parts`: its style
  # attributes, the padding and separator after them, and its contents.
  defp table_tag(state, {markup, tag}, parts) do
    close_open =
      if parts.separator,
        do: %{wiki_markup: parts.separator, padding: parts.padding},
        else: %{padding: parts.padding}

    state
    |> State.emit({:tag_open_open, %{wiki_markup: markup}})
    |> State.emit_text(tag)
    |> State.emit_all(parts.style)
    |> State.emit({:tag_close_open, close_open})
    |> State.emit_all(parts.contents)
    |> State.emit({:tag_open_close, %{}})
    |> State.emit_text(tag)
    |> State.emit({:tag_close_close, %{}})
  end

  # Reads attributes up to `end_char` in a frame of `context`, returning
  # `{state, padding}` with the whitespace after them, `end_char` itself unread.
  defp attributes_frame(state, context, end_char) do
    tag = new_tag(@tag_attr_ready)

    state
    |> State.push(context)
    |> table_attributes(tag, end_char)
  end

  defp table_attributes(state, tag, end_char) do
    char = State.current(state)
    can_close? = not has(tag.context, @tag_quoted) or has(tag.context, @tag_note_space)

    cond do
      char == end_char and can_close? ->
        end_attributes(state, tag, char)

      char in [:end, end_char] ->
        unterminated_attributes(state, tag, &table_attributes(&1, &2, end_char))

      true ->
        {read, read_tag} = tag_char(state, tag, char)
        table_attributes(read, read_tag, end_char)
    end
  end

  defp end_attributes(state, tag, char) do
    {ended, ended_tag} = emit_pending_attribute(state, tag)

    padding =
      if State.space?(char), do: ended_tag.pad_first <> <<char::utf8>>, else: ended_tag.pad_first

    {ended, padding}
  end

  # `{|` at the start of a line opens a table, its attributes on the same line.
  defp table(state) do
    start = state.pos
    after_opening = State.forward(state, 2)

    case State.attempt(after_opening, &attributes_frame(&1, @table_open, ?\n)) do
      {:ok, {read, padding}} ->
        table_contents(read, start, padding)

      {:failed, _context, failed} ->
        failed
        |> State.seek(start)
        |> text_char()
    end
  end

  defp table_contents(state, start, padding) do
    {style, below} = State.pop(state)
    at_contents = State.forward(below)
    restore_point = State.route(at_contents)

    case State.attempt(at_contents, &parse(&1, @table_open)) do
      {:ok, {contents, read}} ->
        table_tag(read, {"{|", "table"}, %{
          style: style,
          padding: padding,
          separator: nil,
          contents: contents
        })

      {:failed, _context, failed} ->
        failed
        |> unwind_to(restore_point)
        |> State.seek(start)
        |> text_char()
    end
  end

  defp unwind_to(state, route) do
    if State.route(state) == route do
      state
    else
      state
      |> State.abandon()
      |> unwind_to(route)
    end
  end

  defp table_cell_markup(state, [?|, ?| | _rest], context) when has(context, @table_td_line),
    do: cell_or_end(state, "||", "td", @table_td_line, context)

  defp table_cell_markup(state, [?|, ?| | _rest], context) when has(context, @table_th_line),
    do: cell_or_end(state, "||", "th", @table_th_line, context)

  defp table_cell_markup(state, [?!, ?! | _rest], context) when has(context, @table_th_line),
    do: cell_or_end(state, "!!", "th", @table_th_line, context)

  defp table_cell_markup(state, [?| | _rest], context) when has(context, @table_cell_style),
    do: table_cell_end(state, true)

  # A line break ends the cells of its line.
  defp table_cell_markup(state, [?\n | _rest], context) when has(context, @table_cell_line) do
    state
    |> State.remove_flags(@table_cell_line)
    |> text_char()
  end

  defp table_cell_markup(state, [char, next | _rest], context) when char in [?|, ?!] do
    if leading_whitespace?(state),
      do: table_line_start(state, char, next, context),
      else: text_char(state)
  end

  defp table_cell_markup(state, _ahead, _context), do: text_char(state)

  defp cell_or_end(state, markup, tag, line_context, context) do
    if has(context, @table_cell_open),
      do: table_cell_end(state),
      else: table_cell(state, markup, tag, line_context)
  end

  defp table_line_start(state, _char, _next, context) when has(context, @table_cell_open),
    do: table_cell_end(state)

  defp table_line_start(state, ?|, next, context)
       when next in [?}, ?-] and has(context, @table_row_open), do: done(State.pop(state))

  defp table_line_start(state, ?|, ?}, _context) do
    state
    |> State.forward(2)
    |> State.pop()
    |> done()
  end

  defp table_line_start(state, ?|, ?-, _context), do: table_row(state)

  defp table_line_start(state, ?|, _next, _context),
    do: table_cell(state, "|", "td", @table_td_line)

  defp table_line_start(state, ?!, _next, _context),
    do: table_cell(state, "!", "th", @table_th_line)

  # `|-` opens a row, its attributes on the same line.
  defp table_row(state) do
    after_markup = State.forward(state, 2)

    if nestable(after_markup),
      do: read_table_row(after_markup),
      else: State.emit_text(after_markup, "|-")
  end

  defp read_table_row(state) do
    context = @table_open ||| @table_row_open
    {attributes, padding} = attributes_frame(state, context, ?\n)
    {style, below} = State.pop(attributes)

    {row, read} =
      below
      |> State.forward()
      |> parse(context)

    table_tag(read, {"|-", "tr"}, %{style: style, padding: padding, separator: nil, contents: row})
  end

  # A cell, `|` or `!` and `||` or `!!` on the same line; `attributes |` may
  # start it.
  defp table_cell(state, markup, tag, line_context) do
    after_markup = State.forward(state, byte_size(markup))

    if nestable(after_markup),
      do: read_table_cell(after_markup, {markup, tag}, line_context, State.context(state)),
      else: State.emit_text(after_markup, markup)
  end

  # Reads the cell as contents; if a `|` on its line ends attributes, reads it
  # again as attributes and contents.
  defp read_table_cell(state, {markup, tag}, line_context, outer_context) do
    cell_context = @table_open ||| @table_cell_open ||| line_context
    {contents, read} = parse(state, cell_context ||| @table_cell_style)
    read_context = State.context(read)
    restored = State.put_context(read, outer_context)

    {cell_read, cell} =
      if has(read_context, @table_cell_style),
        do: styled_table_cell(restored, state.pos, cell_context, outer_context),
        else:
          {restored,
           %{contents: contents, context: read_context, style: [], padding: "", separator: nil}}

    cell_read
    |> table_tag({markup, tag}, cell)
    |> State.add_flags(band(cell.context, @table_th_line ||| @table_td_line))
  end

  defp styled_table_cell(state, contents_start, cell_context, outer_context) do
    {attributes, padding} =
      state
      |> State.seek(contents_start)
      |> attributes_frame(cell_context, ?|)

    {style, below} = State.pop(attributes)

    {contents, read} =
      below
      |> State.forward()
      |> parse(cell_context)

    {State.put_context(read, outer_context),
     %{
       contents: contents,
       context: State.context(read),
       style: style,
       padding: padding,
       separator: "|"
     }}
  end

  defp table_cell_end(state, style_ahead? \\ false) do
    state
    |> mark_cell_style(style_ahead?)
    |> State.pop_keeping_context()
    |> done()
  end

  defp mark_cell_style(state, true), do: State.add_flags(state, @table_cell_style)
  defp mark_cell_style(state, false), do: State.remove_flags(state, @table_cell_style)
end
