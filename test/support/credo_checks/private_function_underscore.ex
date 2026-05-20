defmodule GraphConn.CredoChecks.PrivateFunctionUnderscore do
  @moduledoc """
  Flags private functions whose name doesn't start with `_`.

  Project convention: every `defp` is `defp _name(...)`.
  """
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: "Private functions must start with `_` (e.g. `defp _build_request/2`)."
    ]

  alias Credo.IssueMeta

  @spec run(Credo.SourceFile.t(), params :: Keyword.t()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &_traverse(&1, &2, issue_meta))
  end

  # Unguarded clause: defp foo(args), do: ...
  # Guard-wrapped clauses use the {:when, ...} shape handled below.
  defp _traverse({:defp, meta, [{name, _, _args} | _]} = ast, issues, issue_meta)
       when is_atom(name) and name != :when do
    _check_name(ast, issues, issue_meta, meta, name)
  end

  # Guarded clause: defp foo(args) when guard, do: ...
  defp _traverse(
         {:defp, meta, [{:when, _, [{name, _, _args} | _]} | _]} = ast,
         issues,
         issue_meta
       )
       when is_atom(name) do
    _check_name(ast, issues, issue_meta, meta, name)
  end

  defp _traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp _check_name(ast, issues, issue_meta, meta, name) do
    name
    |> Atom.to_string()
    |> String.starts_with?("_")
    |> case do
      true -> {ast, issues}
      false -> {ast, [_issue(issue_meta, meta, name) | issues]}
    end
  end

  defp _issue(issue_meta, meta, name) do
    format_issue(issue_meta,
      message: "Private function `#{name}` must start with `_`",
      line_no: meta[:line]
    )
  end
end
