defmodule WikitextEx.Text do
  @moduledoc false
  # Whitespace as wikitext parsing sees it: the characters below, which include
  # the C0 separators U+001C..U+001F that Unicode's White_Space leaves out.

  # The file, group, record and unit separators.
  @information_separators 0x1C..0x1F
  # The en quad to the hair space.
  @typographic_spaces 0x2000..0x200A
  @other_spaces [
    # next line
    0x85,
    # no-break space
    0xA0,
    # Ogham space mark
    0x1680,
    # line separator
    0x2028,
    # paragraph separator
    0x2029,
    # narrow no-break space
    0x202F,
    # medium mathematical space
    0x205F,
    # ideographic space
    0x3000
  ]

  @doc "Whether the character `char` is whitespace."
  defguard space_char?(char)
           when char in ?\t..?\r or char == ?\s or char in @information_separators or
                  char in @typographic_spaces or char in @other_spaces

  @doc "Whether `text` is non-empty and all whitespace."
  @spec space?(term()) :: boolean()
  def space?(text) when is_binary(text) and text != "", do: all_space?(text)
  def space?(_text), do: false

  @doc "`text` without leading whitespace."
  @spec trim_leading(String.t()) :: String.t()
  def trim_leading(<<char::utf8, rest::binary>>) when space_char?(char), do: trim_leading(rest)
  def trim_leading(text), do: text

  @doc "`text` without trailing whitespace."
  @spec trim_trailing(String.t()) :: String.t()
  def trim_trailing(text), do: binary_part(text, 0, content_size(text, byte_size(text)))

  @doc "`text` split into its leading whitespace, its content, and its trailing whitespace."
  @spec split_padding(String.t()) :: {String.t(), String.t(), String.t()}
  def split_padding(text) do
    rest = trim_leading(text)
    content = trim_trailing(rest)
    leading_size = byte_size(text) - byte_size(rest)
    trailing = binary_part(rest, byte_size(content), byte_size(rest) - byte_size(content))
    {binary_part(text, 0, leading_size), content, trailing}
  end

  defp all_space?(<<char::utf8, rest::binary>>) when space_char?(char), do: all_space?(rest)
  defp all_space?(<<>>), do: true
  defp all_space?(_text), do: false

  # The byte size of the first `size` bytes of `text` without their trailing
  # whitespace, read from the end: a whitespace character is one to three bytes.
  defp content_size(text, size) do
    case Enum.find(1..3//1, &trailing_space?(text, size, &1)) do
      nil -> size
      bytes -> content_size(text, size - bytes)
    end
  end

  defp trailing_space?(text, size, bytes) when bytes <= size do
    case binary_part(text, size - bytes, bytes) do
      <<char::utf8>> -> space_char?(char)
      _partial -> false
    end
  end

  defp trailing_space?(_text, _size, _bytes), do: false
end
