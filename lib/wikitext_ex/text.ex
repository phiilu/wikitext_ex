defmodule WikitextEx.Text do
  @moduledoc false
  # Whitespace as wikitext parsing sees it: the characters below, which include
  # the C0 separators U+001C..U+001F that Unicode's White_Space leaves out.

  @doc "Whether `text` is non-empty and all whitespace."
  @spec space?(term()) :: boolean()
  def space?(text) when is_binary(text) and text != "", do: all_space?(text)
  def space?(_text), do: false

  @doc "`text` without leading whitespace."
  @spec trim_leading(String.t()) :: String.t()
  def trim_leading(text), do: drop_leading_space(text)

  @doc "`text` without trailing whitespace."
  @spec trim_trailing(String.t()) :: String.t()
  def trim_trailing(text), do: binary_part(text, 0, content_end(text, 0, 0))

  @doc "`text` without leading and trailing whitespace."
  @spec strip(String.t()) :: String.t()
  def strip(text) do
    text
    |> trim_leading()
    |> trim_trailing()
  end

  defguardp space_char?(char)
            when char in 0x9..0xD or char in 0x1C..0x20 or char in 0x2000..0x200A or
                   char in [0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

  defp all_space?(<<char::utf8, rest::binary>>) when space_char?(char), do: all_space?(rest)
  defp all_space?(<<>>), do: true
  defp all_space?(_text), do: false

  defp drop_leading_space(<<char::utf8, rest::binary>>) when space_char?(char),
    do: drop_leading_space(rest)

  defp drop_leading_space(text), do: text

  # The byte offset just past the last non-whitespace character.
  defp content_end(<<char::utf8, rest::binary>>, offset, last) when space_char?(char),
    do: content_end(rest, offset + char_size(char), last)

  defp content_end(<<char::utf8, rest::binary>>, offset, _last) do
    end_of_char = offset + char_size(char)
    content_end(rest, end_of_char, end_of_char)
  end

  defp content_end(<<>>, _offset, last), do: last

  defp char_size(char), do: byte_size(<<char::utf8>>)
end
