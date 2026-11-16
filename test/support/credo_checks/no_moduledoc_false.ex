defmodule GraphConn.CredoChecks.NoModuledocFalse do
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: "Write a one-line `@moduledoc`, or `@moduledoc !\"...\"` to keep it out of hexdocs."
    ]

  # After `use Credo.Check`, which sets a public @moduledoc of its own.
  @moduledoc !"""
             Flags `@moduledoc false`.

             Project convention: every module says in one line what it is. A module kept out of the API docs
             says it privately, with `@moduledoc !"..."`.
             """

  alias Credo.IssueMeta

  @spec run(Credo.SourceFile.t(), params :: Keyword.t()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &_traverse(&1, &2, issue_meta))
  end

  defp _traverse({:@, meta, [{:moduledoc, _doc_meta, [false]}]} = ast, issues, issue_meta),
    do: {ast, [_issue(issue_meta, meta) | issues]}

  defp _traverse(ast, issues, _issue_meta),
    do: {ast, issues}

  defp _issue(issue_meta, meta) do
    issue_meta
    |> format_issue(
      message:
        "`@moduledoc false`: write a one-line moduledoc, or `@moduledoc !\"...\"` to keep it private",
      line_no: meta[:line]
    )
  end
end
