defmodule WikitextEx.Checks.SingleLetterVariableTest do
  use ExUnit.Case, async: true

  alias WikitextEx.Checks.SingleLetterVariable

  defp issues(source_code) do
    source_code
    |> Credo.SourceFile.parse("lib/example.ex")
    |> SingleLetterVariable.run([])
    |> Enum.map(&{&1.trigger, &1.line_no})
  end

  test "flags a single-letter parameter, once per line" do
    source = """
    defmodule Example do
      def forward(s, count), do: %{s | pos: s.pos + count}
    end
    """

    assert issues(source) == [{"s", 2}]
  end

  test "flags single letters bound in patterns, anonymous functions and comprehensions" do
    source = """
    defmodule Example do
      def pairs(map) do
        {a, _rest} = {1, 2}
        Map.new(map, fn {k, value} -> {k, value + a} end)
        for c <- [1], do: c
      end
    end
    """

    assert issues(source) == [{"a", 3}, {"k", 4}, {"a", 4}, {"c", 5}]
  end

  test "flags an unused single letter" do
    source = """
    defmodule Example do
      def first([head | _t]), do: head
    end
    """

    assert issues(source) == [{"_t", 2}]
  end

  test "allows longer names, the bare underscore, and letters that aren't variables" do
    source = """
    defmodule Example do
      @x 1
      @spec run(t()) :: t()
      def run([state | _]), do: {state, @x, ?x, :x, "x", ~c"x"}
    end
    """

    assert issues(source) == []
  end
end
