defmodule GraphConn.CredoChecks.PipeIntoCase do
  @moduledoc """
  Flags `case` whose subject is a function call or a pipe, such as `case f(x) do`, instead of
  piping into `case`.

  A variable, literal, operator expression, field access (`state.x`) or bracket access
  (`map[:k]`) as the subject is fine.
  """
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      Pipe into `case` rather than calling inside its head:

          x
          |> f()
          |> case do
            {:ok, value} -> value
            {:error, reason} -> raise reason
          end
      """
    ]

  alias Credo.IssueMeta

  @not_calls ~w(
    fn & @ ^ {} %{} % <<>> __block__ __aliases__ __MODULE__ __ENV__ __CALLER__ __DIR__
    __STACKTRACE__ unquote unquote_splicing
  )a

  @spec run(Credo.SourceFile.t(), params :: Keyword.t()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &_traverse(&1, &2, issue_meta))
  end

  defp _traverse({:case, meta, [subject, _clauses]} = ast, issues, issue_meta) do
    subject
    |> _call_or_pipe?()
    |> case do
      true -> {ast, [_issue(issue_meta, meta) | issues]}
      false -> {ast, issues}
    end
  end

  defp _traverse(ast, issues, _issue_meta),
    do: {ast, issues}

  defp _call_or_pipe?({:|>, _meta, _operands}),
    do: true

  defp _call_or_pipe?({name, _meta, args} = ast) when is_atom(name) and is_list(args) do
    arity = length(args)
    not (name in @not_calls or Macro.operator?(name, arity) or _sigil?(name) or _access?(ast))
  end

  defp _call_or_pipe?({{:., _dot_meta, _callee}, _meta, args} = ast) when is_list(args),
    do: not _access?(ast)

  defp _call_or_pipe?(_ast),
    do: false

  defp _access?({{:., _dot_meta, [Access, :get]}, meta, _args}),
    do: Keyword.get(meta, :from_brackets, false)

  defp _access?({{:., _dot_meta, [_receiver, field]}, meta, []}) when is_atom(field),
    do: Keyword.get(meta, :no_parens, false)

  defp _access?(_ast),
    do: false

  defp _sigil?(name) do
    name
    |> Atom.to_string()
    |> String.starts_with?("sigil_")
  end

  defp _issue(issue_meta, meta) do
    issue_meta
    |> format_issue(
      message: "`case` on a call or pipe; pipe into `case` instead",
      line_no: meta[:line]
    )
  end
end
