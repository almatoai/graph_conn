defmodule GraphConn.CredoChecks.NoPipeInsideCall do
  @moduledoc """
  Flags pipe chains used directly as function-call arguments.

  Project convention: extract such pipes to a named value or restructure as a
  top-level pipe.
  """
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      Don't write `foo(x |> bar(), y)`. Extract the pipe to a variable or pipe
      into `foo`:

          x_bar = x |> bar()
          foo(x_bar, y)

      or

          x |> bar() |> foo(y)
      """
    ]

  alias Credo.IssueMeta

  @spec run(Credo.SourceFile.t(), params :: Keyword.t()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &_traverse(&1, &2, issue_meta))
  end

  # AST forms whose children are not "function-call arguments" — bodies,
  # clauses, blocks, operators. Skip these so we don't flag pipes inside
  # function bodies, control flow, blocks, etc. The intent is to flag only
  # genuine `foo(x |> bar(), y)` constructs.
  @skip_forms ~w(
    def defp defmacro defmacrop defguard defguardp
    defmodule defprotocol defimpl defstruct defexception
    fn & quote unquote unquote_splicing
    if unless case cond with for try receive
    when -> |> = :: ++ -- + - * / == != === !== < > <= >= && || ! and or not in
    __block__ __aliases__ __MODULE__ __ENV__ __CALLER__ __STACKTRACE__
  )a

  defp _traverse({fn_name, _meta, args} = ast, issues, issue_meta)
       when is_atom(fn_name) and is_list(args) and fn_name not in @skip_forms do
    new =
      args
      |> Enum.filter(&_is_pipe/1)
      |> Enum.map(&_issue(issue_meta, &1))

    {ast, new ++ issues}
  end

  defp _traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp _is_pipe({:|>, _, _}), do: true
  defp _is_pipe(_), do: false

  defp _issue(issue_meta, {_, meta, _}) do
    format_issue(issue_meta,
      message: "Pipe `|>` used directly as function-call argument",
      line_no: meta[:line]
    )
  end
end
