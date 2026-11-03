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
  # clauses, blocks, data literals. Operators are skipped separately. The
  # intent is to flag only genuine `foo(x |> bar(), y)` constructs.
  @skip_forms ~w(
    def defp defmacro defmacrop defguard defguardp
    defmodule defprotocol defimpl defstruct defexception
    fn quote unquote unquote_splicing
    if unless case cond with for try receive
    -> {} <<>>
    __block__ __aliases__ __MODULE__ __ENV__ __CALLER__ __STACKTRACE__
  )a

  # Keyword keys that carry a `do … end` block body, alongside `:do`, rather than an argument.
  @block_keys [:do, :else, :after, :rescue, :catch]

  # A module attribute definition (`@sha x |> f()`) is not a call: check its value only.
  defp _traverse({:@, meta, [{name, _name_meta, [value]}]}, issues, _issue_meta)
       when is_atom(name),
       do: {{:__block__, meta, [value]}, issues}

  defp _traverse({fn_name, _meta, args} = ast, issues, issue_meta)
       when is_atom(fn_name) and is_list(args) and fn_name not in @skip_forms do
    args
    |> length()
    |> then(&Macro.operator?(fn_name, &1))
    |> case do
      true -> {ast, issues}
      false -> {ast, _pipe_issues(args, issue_meta) ++ issues}
    end
  end

  defp _traverse({{:., _dot_meta, _callee}, meta, args} = ast, issues, issue_meta)
       when is_list(args) do
    meta
    |> Keyword.get(:from_interpolation, false)
    |> case do
      # `"#{x |> f()}"` compiles to a `Kernel.to_string/1` call, allowed by convention.
      true -> {ast, issues}
      false -> {ast, _pipe_issues(args, issue_meta) ++ issues}
    end
  end

  defp _traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp _pipe_issues(args, issue_meta) do
    args
    |> List.last()
    |> _keyword_values()
    |> Kernel.++(args)
    |> Enum.filter(&_is_pipe/1)
    |> Enum.map(&_issue(issue_meta, &1))
  end

  defp _keyword_values([{key, _value} | _rest] = keyword) when is_atom(key) do
    do_block? = Keyword.has_key?(keyword, :do)
    for {key, value} <- keyword, not (do_block? and key in @block_keys), do: value
  end

  defp _keyword_values(_last_arg), do: []

  defp _is_pipe({:|>, _meta, _operands}), do: true
  defp _is_pipe(_ast), do: false

  defp _issue(issue_meta, {:|>, meta, _operands}) do
    issue_meta
    |> format_issue(
      message: "Pipe `|>` used directly as function-call argument",
      line_no: meta[:line]
    )
  end
end
