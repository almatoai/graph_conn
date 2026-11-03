defmodule GraphConn.CredoChecks.LazyLoggerMessage do
  @moduledoc ~S"""
  Flags a `Logger` call whose message holds a variable bound earlier in an enclosing block from
  anything but a function.

  Logger macros build their message only when the level is enabled. A message bound ahead of the
  call is built every time, so an `inspect/1` in it runs even with the level off.

  The message may be the variable itself, a string interpolating it, or a `<>` concatenation with
  it as an operand. The call may sit directly in the binding's block or anywhere nested in a later
  statement of it (inside an `if`, `case`, ...).

  Exempt:

    * a variable also used anywhere else in its block, since it is needed regardless of the log.
      A rebinding such as `message = message <> "!"` counts as such a use;
    * a function-valued variable (`log = fn -> ... end`), called only when the level is enabled;
    * a variable not bound in an enclosing block, such as a function parameter;
    * a variable passed only as metadata (`Logger.info("x", detail: detail)`). Metadata is lazy
      too, so this is a known gap: only the message is examined.

  Also a known gap: a variable logged by two Logger calls (`Logger.info(m)` in one branch,
  `Logger.warning(m)` in the other) is not flagged, as each call counts as the other's use.

  When the message names the caller's pid from inside a spawned `fn`, bind the pid, not its
  string: `caller = self()` outside and `#{inspect(caller)}` inside. Moving `inspect(self())`
  into the `fn` would log the spawned process instead.
  """
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: ~S"""
      Keep a log message inside the Logger call so it is built only when the level is enabled:

          "Executing #{name} with #{inspect(params)}"
          |> Logger.info()

      rather than

          message = "Executing #{name} with #{inspect(params)}"
          Logger.info(message)
      """
    ]

  alias Credo.IssueMeta

  @levels ~w(debug info notice warning warn error critical alert emergency)a

  @spec run(Credo.SourceFile.t(), params :: Keyword.t()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.Code.prewalk(&_traverse(&1, &2, issue_meta))
    |> Enum.uniq_by(&{&1.line_no, &1.message})
  end

  defp _traverse({:__block__, _meta, statements} = ast, issues, issue_meta) do
    block_issues =
      statements
      |> Enum.with_index()
      |> Enum.flat_map(&_statement_issues(&1, statements, issue_meta))

    {ast, block_issues ++ issues}
  end

  defp _traverse(ast, issues, _issue_meta),
    do: {ast, issues}

  # Every Logger call anywhere in the statement, paired with this block's earlier bindings.
  defp _statement_issues({statement, index}, statements, issue_meta) do
    for {line, name, message} <- _logged_vars(statement),
        {:ok, _binding_index} <- [_bound_before(statements, index, name)],
        not _used_elsewhere?(statements, index, name, message) do
      _issue(issue_meta, line, name)
    end
  end

  defp _logged_vars(statement) do
    {_ast, logged} =
      statement
      |> Macro.prewalk([], fn node, logged -> {node, _logged_message(node) ++ logged} end)

    logged
  end

  defp _logged_message({:|>, _meta, [message, {{:., _dot_meta, [logger, level]}, meta, _args}]}),
    do: _when_logger(logger, level, message, meta)

  defp _logged_message({{:., _dot_meta, [logger, :log]}, meta, [_level, message | _rest]}),
    do: _when_logger(logger, :info, message, meta)

  defp _logged_message({{:., _dot_meta, [logger, level]}, meta, [message | _rest]}),
    do: _when_logger(logger, level, message, meta)

  defp _logged_message(_node),
    do: []

  defp _when_logger({:__aliases__, _alias_meta, [:Logger]}, level, message, meta)
       when level in @levels do
    for name <- _message_vars(message), do: {meta[:line], name, message}
  end

  defp _when_logger(_module, _level, _message, _meta),
    do: []

  defp _message_vars({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: [name]

  defp _message_vars({:<>, _meta, operands}),
    do: Enum.flat_map(operands, &_message_vars/1)

  defp _message_vars({:<<>>, _meta, parts}),
    do: Enum.flat_map(parts, &_interpolated_vars/1)

  defp _message_vars(_message),
    do: []

  defp _interpolated_vars(
         {:"::", _meta, [{{:., _dot_meta, [Kernel, :to_string]}, _call, [value]}, _type]}
       ),
       do: _message_vars(value)

  defp _interpolated_vars(_part),
    do: []

  # The latest binding of `name` ahead of `index`, unless what it binds is a function.
  defp _bound_before(statements, index, name) do
    statements
    |> Enum.take(index)
    |> Enum.reverse()
    |> Enum.find_value(:error, fn
      {:=, _meta, [{^name, _var_meta, context}, value]} when is_atom(context) ->
        _unless_function(value)

      _other ->
        nil
    end)
  end

  defp _unless_function({:fn, _meta, _clauses}),
    do: :error

  defp _unless_function({:&, _meta, _capture}),
    do: :error

  defp _unless_function(_value),
    do: {:ok, :bound}

  # Any reference in the block besides the binding's own left-hand side and the logged message.
  defp _used_elsewhere?(statements, index, name, message) do
    logged_statement = Enum.at(statements, index)
    in_message = _count_references(message, name)
    in_logged_statement = _count_references(logged_statement, name) - in_message

    in_other_statements =
      statements
      |> List.delete_at(index)
      |> Enum.map(&_count_references(&1, name))
      |> Enum.sum()

    in_logged_statement + in_other_statements > 1
  end

  defp _count_references(ast, name) do
    {_ast, count} =
      ast
      |> Macro.prewalk(0, fn
        {^name, _meta, context} = node, count when is_atom(context) -> {node, count + 1}
        node, count -> {node, count}
      end)

    count
  end

  defp _issue(issue_meta, line, name) do
    issue_meta
    |> format_issue(
      message: "Log message `#{name}` is built before the Logger call; build it inside the call",
      line_no: line
    )
  end
end
