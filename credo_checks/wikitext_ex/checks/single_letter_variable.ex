if Code.ensure_loaded?(Credo.Check) do
  defmodule WikitextEx.Checks.SingleLetterVariable do
    @moduledoc false

    use Credo.Check,
      base_priority: :high,
      category: :readability,
      explanations: [
        check: """
        A variable's name says what it holds. A single letter says nothing, so
        name it for its content, unused variables included.

        This should be refactored:

            def forward(s, n), do: %{s | pos: s.pos + n}

        to look like this:

            def forward(state, count), do: %{state | pos: state.pos + count}
        """
      ]

    alias Credo.SourceFile

    @impl Credo.Check
    def run(%SourceFile{} = source_file, params) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&traverse/2)
      |> Enum.uniq()
      |> Enum.reverse()
      |> Enum.map(&issue_for(issue_meta, &1))
    end

    # A module attribute's name parses like a variable; skip the attribute.
    defp traverse({:@, meta, _attribute}, found), do: {{:@, meta, []}, found}

    defp traverse({name, meta, context} = ast, found) when is_atom(name) and is_atom(context) do
      if single_letter?(name),
        do: {ast, [{Atom.to_string(name), meta[:line]} | found]},
        else: {ast, found}
    end

    defp traverse(ast, found), do: {ast, found}

    defp single_letter?(name) do
      name
      |> Atom.to_string()
      |> String.trim_leading("_")
      |> String.length()
      |> Kernel.==(1)
    end

    defp issue_for(issue_meta, {name, line}) do
      format_issue(issue_meta,
        message: "Name the variable `#{name}` for what it holds.",
        trigger: name,
        line_no: line
      )
    end
  end
end
