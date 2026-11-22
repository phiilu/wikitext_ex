defmodule WikitextEx.Tokenizer.State do
  @moduledoc false
  # The tokenizer's state: the text, the position in it, and a stack of frames,
  # one for each construct being read.
  #
  # A frame collects the tokens of its construct and the text read since its
  # last token, under a context of flags that says what may come next. The
  # frame's route is where it was pushed: the position and the context.
  #
  # Reading a construct can turn out to be wrong: `{{` that is never closed is
  # not a template. The construct then fails: its frame is dropped, its route
  # remembered, and the caller, the nearest `attempt/2`, reads the opening as
  # text instead. A remembered route fails again at once when pushed, which
  # keeps unterminated markup from being read over and over.

  import Bitwise

  alias WikitextEx.Text

  # How deep constructs may nest before markup is read as text.
  @max_depth 100

  defstruct text: "",
            pos: 0,
            frames: [],
            depth: 0,
            heading?: false,
            failed_routes: MapSet.new(),
            skip_style_tags?: false

  @type t() :: %__MODULE__{}

  defmodule Frame do
    @moduledoc false
    defstruct tokens: [], text: [], context: 0, route: nil
  end

  @spec new(String.t(), boolean()) :: t()
  def new(text, skip_style_tags?), do: %__MODULE__{text: text, skip_style_tags?: skip_style_tags?}

  # --- Reading ------------------------------------------------------------------

  @doc "The character at the position, or `:end`."
  @spec current(t()) :: char() | :end
  def current(%{text: text, pos: pos}), do: char_at(text, pos)

  @doc "The `count` characters from the position on, `:end` past the text."
  @spec ahead(t(), pos_integer()) :: [char() | :end]
  def ahead(%{text: text, pos: pos}, count), do: chars_from(text, pos, count)

  @doc "The character `n` characters ahead of the position, or `:end`."
  @spec peek(t(), non_neg_integer()) :: char() | :end
  def peek(s, n) do
    s
    |> ahead(n + 1)
    |> List.last()
  end

  @doc "The character `n` characters behind the position, or `:start`."
  @spec behind(t(), pos_integer()) :: char() | :start
  def behind(%{text: text, pos: pos}, n), do: char_before(text, pos, n)

  @doc "Moves the position `count` characters on."
  @spec forward(t(), non_neg_integer()) :: t()
  def forward(s, count \\ 1)
  def forward(s, 0), do: s

  def forward(%{text: text, pos: pos} = s, count) do
    case char_at(text, pos) do
      :end -> s
      char -> forward(%{s | pos: pos + char_size(char)}, count - 1)
    end
  end

  @doc "Moves the position to `pos`, a byte offset saved earlier."
  @spec seek(t(), non_neg_integer()) :: t()
  def seek(s, pos), do: %{s | pos: pos}

  @doc "The text from the position up to the first byte `stop?` holds for."
  @spec text_run(t(), (byte() -> boolean())) :: String.t()
  def text_run(%{text: text, pos: pos}, stop?) do
    <<_read::binary-size(^pos), rest::binary>> = text
    binary_part(rest, 0, run_length(rest, stop?, 0))
  end

  @doc "The text from the position on."
  @spec rest(t()) :: String.t()
  def rest(%{text: text, pos: pos}), do: binary_part(text, pos, byte_size(text) - pos)

  @doc "Whether `char` is whitespace."
  @spec space?(char() | :start | :end) :: boolean()
  def space?(char) when is_integer(char), do: Text.space?(<<char::utf8>>)
  def space?(_edge), do: false

  # --- Frames -------------------------------------------------------------------

  @doc "The context of the current frame."
  @spec context(t()) :: non_neg_integer()
  def context(%{frames: [frame | _frames]}), do: frame.context

  @spec put_context(t(), non_neg_integer()) :: t()
  def put_context(s, context), do: update_frame(s, &%{&1 | context: context})

  @spec add_flags(t(), non_neg_integer()) :: t()
  def add_flags(s, flags), do: put_context(s, bor(context(s), flags))

  @spec remove_flags(t(), non_neg_integer()) :: t()
  def remove_flags(s, flags), do: put_context(s, band(context(s), bnot(flags)))

  @spec toggle_flags(t(), non_neg_integer()) :: t()
  def toggle_flags(s, flags), do: put_context(s, bxor(context(s), flags))

  @doc "The route of the current frame."
  @spec route(t()) :: {non_neg_integer(), non_neg_integer()}
  def route(%{frames: [frame | _frames]}), do: frame.route

  @doc "The tokens of the current frame, in order."
  @spec tokens(t()) :: [term()]
  def tokens(%{frames: [frame | _frames]}), do: Enum.reverse(frame.tokens)

  @doc "The text read since the current frame's last token, newest chunk first."
  @spec pending_text(t()) :: [String.t()]
  def pending_text(%{frames: [frame | _frames]}), do: frame.text

  @spec put_pending_text(t(), [String.t()]) :: t()
  def put_pending_text(s, text), do: update_frame(s, &%{&1 | text: text})

  @doc "Removes the current frame's last token, which follows all its text."
  @spec take_last_token(t()) :: {term(), t()}
  def take_last_token(
        %{frames: [%Frame{tokens: [token | tokens], text: []} = frame | frames]} = s
      ), do: {token, %{s | frames: [%{frame | tokens: tokens} | frames]}}

  @doc "Replaces the current frame's tokens, in order, with `fun` of them."
  @spec map_tokens(t(), ([term()] -> [term()])) :: t()
  def map_tokens(s, fun) do
    s
    |> flush_text()
    |> update_frame(&%{&1 | tokens: map_in_order(&1.tokens, fun)})
  end

  @doc "Pushes a frame with `context`; fails at once on a remembered route."
  @spec push(t(), non_neg_integer()) :: t()
  def push(s, context \\ 0) do
    route = {s.pos, context}
    if MapSet.member?(s.failed_routes, route), do: throw({:route_failed, context, s})
    %{s | frames: [%Frame{context: context, route: route} | s.frames], depth: s.depth + 1}
  end

  @doc "Whether pushing a frame with `context` here would fail."
  @spec failed_route?(t(), non_neg_integer()) :: boolean()
  def failed_route?(s, context), do: MapSet.member?(s.failed_routes, {s.pos, context})

  @doc """
  Pops the current frame, returning its tokens. With `keep_context: true` the
  frame below takes over its context.
  """
  @spec pop(t(), keyword()) :: {[term()], t()}
  def pop(s, opts \\ []) do
    %{frames: [frame | frames]} = flushed = flush_text(s)
    popped = %{flushed | frames: frames, depth: flushed.depth - 1}
    below = if opts[:keep_context], do: put_context(popped, frame.context), else: popped
    {Enum.reverse(frame.tokens), below}
  end

  @doc "Drops the current frame."
  @spec drop(t()) :: t()
  def drop(s) do
    {_tokens, below} = pop(s)
    below
  end

  @doc "Remembers the current frame's route as failed."
  @spec remember_failure(t()) :: t()
  def remember_failure(s), do: %{s | failed_routes: MapSet.put(s.failed_routes, route(s))}

  # --- Failing ------------------------------------------------------------------

  @doc "Fails the current frame's construct: drops the frame, remembering its route."
  @spec fail(t()) :: no_return()
  def fail(s) do
    failed =
      s
      |> remember_failure()
      |> drop()

    throw({:route_failed, context(s), failed})
  end

  @doc "Fails the construct being read before it has a frame of its own."
  @spec reject(t()) :: no_return()
  def reject(s), do: throw({:route_failed, 0, s})

  @doc """
  Runs `fun` on `s`: `{:ok, result}`, or `{:failed, context, s}` with the
  failed frame's context and the state as it failed.
  """
  @spec attempt(t(), (t() -> result)) :: {:ok, result} | {:failed, non_neg_integer(), t()}
        when result: term()
  def attempt(s, fun) do
    {:ok, fun.(s)}
  catch
    {:route_failed, context, failed} -> {:failed, context, failed}
  end

  @doc "Like `attempt/2`, but a failure fails the caller as well, from `pos`."
  @spec attempt_or_fail_from(t(), non_neg_integer(), (t() -> result)) :: result
        when result: term()
  def attempt_or_fail_from(s, pos, fun) do
    case attempt(s, fun) do
      {:ok, result} -> result
      {:failed, context, failed} -> throw({:route_failed, context, seek(failed, pos)})
    end
  end

  # --- Emitting -----------------------------------------------------------------

  @spec emit(t(), term()) :: t()
  def emit(s, token) do
    s
    |> flush_text()
    |> update_frame(&%{&1 | tokens: [token | &1.tokens]})
  end

  @doc "Puts `token` before all others of the current frame."
  @spec emit_first(t(), term()) :: t()
  def emit_first(s, token) do
    s
    |> flush_text()
    |> update_frame(&%{&1 | tokens: List.insert_at(&1.tokens, -1, token)})
  end

  @spec emit_text(t(), String.t()) :: t()
  def emit_text(s, text), do: update_frame(s, &%{&1 | text: [text | &1.text]})

  @spec emit_char(t(), char()) :: t()
  def emit_char(s, char), do: emit_text(s, <<char::utf8>>)

  @doc "Emits `tokens`, a leading text token joining the pending text."
  @spec emit_all(t(), [term()]) :: t()
  def emit_all(s, []), do: s

  def emit_all(s, [text | tokens]) when is_binary(text) do
    s
    |> emit_text(text)
    |> emit_all(tokens)
  end

  def emit_all(s, tokens) do
    s
    |> flush_text()
    |> update_frame(&%{&1 | tokens: Enum.reverse(tokens, &1.tokens)})
  end

  # --- Private ------------------------------------------------------------------

  defp run_length(<<byte, rest::binary>>, stop?, length) do
    if stop?.(byte), do: length, else: run_length(rest, stop?, length + 1)
  end

  defp run_length(<<>>, _stop?, length), do: length

  defp char_at(text, pos) do
    case text do
      <<_read::binary-size(^pos), char::utf8, _rest::binary>> -> char
      _past_the_end -> :end
    end
  end

  defp chars_from(_text, _pos, 0), do: []

  defp chars_from(text, pos, count) do
    case char_at(text, pos) do
      :end -> List.duplicate(:end, count)
      char -> [char | chars_from(text, pos + char_size(char), count - 1)]
    end
  end

  defp char_before(_text, 0, _n), do: :start

  defp char_before(text, pos, n) do
    start = char_start(text, pos - 1)
    if n == 1, do: char_at(text, start), else: char_before(text, start, n - 1)
  end

  # The offset where the UTF-8 character with a byte at `offset` starts.
  defp char_start(text, offset) do
    if band(:binary.at(text, offset), 0xC0) == 0x80,
      do: char_start(text, offset - 1),
      else: offset
  end

  defp char_size(char) when char < 0x80, do: 1
  defp char_size(char) when char < 0x800, do: 2
  defp char_size(char) when char < 0x10000, do: 3
  defp char_size(_char), do: 4

  # Frames keep their tokens newest first.
  defp map_in_order(tokens, fun) do
    tokens
    |> Enum.reverse()
    |> fun.()
    |> Enum.reverse()
  end

  # Turns the pending text into a text token.
  defp flush_text(%{frames: [%Frame{text: []} | _frames]} = s), do: s

  defp flush_text(s) do
    update_frame(s, fn frame ->
      text =
        frame.text
        |> Enum.reverse()
        |> IO.iodata_to_binary()

      %{frame | tokens: [text | frame.tokens], text: []}
    end)
  end

  defp update_frame(%{frames: [frame | frames]} = s, fun),
    do: %{s | frames: [fun.(frame) | frames]}

  defguard nestable(s) when :erlang.map_get(:depth, s) < @max_depth
end
