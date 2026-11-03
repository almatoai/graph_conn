defmodule GraphConn.CredoChecks.PipeMultilineCall do
  @moduledoc """
  Flags a function call that spans several lines without its first argument piped in.

  A call is multi-line when its closing parenthesis, or its last argument for a call without
  parentheses, sits on a later line than its name. A call on the right of `|>` is piped.

  Not checked: macros taking code (definitions, control flow, `use`/`import`/`alias`/`require`,
  ExUnit assertions, any call with a `do ... end` block), operators, special forms, sigils, field
  and bracket access, string interpolation, and typespec attributes.
  """
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      A call that breaks across lines pipes its first argument in:

          vals
          |> Enum.reduce(value, fn {secret, _}, acc ->
            String.replace(acc, secret, @placeholder)
          end)

      When the first argument is itself a multi-line `fn`, bind it to a named value and pipe that.
      """
    ]

  alias Credo.IssueMeta

  @macro_forms ~w(
    def defp defmacro defmacrop defguard defguardp defdelegate defoverridable
    defmodule defprotocol defimpl defstruct defexception
    use import alias require config import_config plug
    if unless case cond with for try receive fn quote unquote unquote_splicing super
    assert refute assert_raise assert_receive assert_received refute_receive refute_received
    assert_in_delta refute_in_delta catch_error catch_exit catch_throw
    describe test setup setup_all
    __block__ __aliases__ __MODULE__ __ENV__ __CALLER__ __DIR__ __STACKTRACE__
    -> {} %{} % <<>> & @ ^ :: when
  )a

  @typespec_attributes ~w(spec type typep opaque callback macrocallback)a

  @definitions ~w(def defp defmacro defmacrop defguard defguardp defdelegate)a

  @spec run(Credo.SourceFile.t(), params :: Keyword.t()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    traverse = &_traverse(&1, &2, issue_meta)

    {issues, _piped} =
      source_file
      |> Credo.Code.prewalk(traverse, {[], MapSet.new()})

    issues
  end

  defp _traverse({:@, _meta, [{attribute, _attribute_meta, _value}]}, acc, _issue_meta)
       when attribute in @typespec_attributes,
       do: {nil, acc}

  # `@name value` defines an attribute: only its value holds calls.
  defp _traverse({:@, meta, [{name, _name_meta, [value]}]}, acc, _issue_meta)
       when is_atom(name),
       do: {{:__block__, meta, [value]}, acc}

  # A function head is a pattern, not a call: only the body and options are walked.
  defp _traverse({definition, meta, [_head | rest]}, acc, _issue_meta)
       when definition in @definitions,
       do: {{:__block__, meta, rest}, acc}

  # Visited before its operands, so the right-hand call is known as piped by the time it is seen.
  defp _traverse({:|>, _meta, [_lhs, {_callee, rhs_meta, _args}]} = ast, {issues, piped}, _im),
    do: {ast, {issues, rhs_meta |> _position() |> then(&MapSet.put(piped, &1))}}

  defp _traverse({_callee, meta, [_first | _rest]} = ast, {issues, piped} = acc, issue_meta) do
    position = _position(meta)
    piped? = MapSet.member?(piped, position)

    case _checked_call?(ast) and not piped? and _multiline?(ast) do
      true -> {ast, {[_issue(issue_meta, meta) | issues], piped}}
      false -> {ast, acc}
    end
  end

  defp _traverse(ast, acc, _issue_meta),
    do: {ast, acc}

  defp _position(meta),
    do: {meta[:line], meta[:column]}

  defp _checked_call?({name, meta, args}) when is_atom(name) do
    arity = length(args)

    not (name in @macro_forms or Macro.operator?(name, arity) or _sigil?(name) or
           Keyword.has_key?(meta, :do))
  end

  defp _checked_call?({{:., _dot_meta, [Kernel, :to_string]}, meta, _args}),
    do: not Keyword.get(meta, :from_interpolation, false)

  # `Mod.{A, B}` in `alias` / `import` names modules; it is not a call.
  defp _checked_call?({{:., _dot_meta, [_module, :{}]}, _meta, _args}),
    do: false

  defp _checked_call?({{:., _dot_meta, [Access, :get]}, meta, _args}),
    do: not Keyword.get(meta, :from_brackets, false)

  defp _checked_call?(
         {{:., _dot_meta, [{:__aliases__, _alias_meta, [:Kernel]}, name]}, _meta, args}
       ) do
    arity = length(args)
    not Macro.operator?(name, arity)
  end

  defp _checked_call?({{:., _dot_meta, _callee}, meta, _args}),
    do: not Keyword.has_key?(meta, :do)

  defp _checked_call?(_ast),
    do: false

  defp _multiline?({_callee, meta, _args} = ast) do
    last_line =
      meta
      |> Keyword.get(:closing, [])
      |> Keyword.get(:line)
      |> case do
        nil -> _last_line(ast)
        closing_line -> closing_line
      end

    last_line > meta[:line]
  end

  defp _last_line(ast) do
    {_ast, last_line} =
      ast
      |> Macro.prewalk(0, fn
        {_form, meta, _args} = node, last when is_list(meta) -> {node, _max_line(meta, last)}
        node, last -> {node, last}
      end)

    last_line
  end

  defp _max_line(meta, last) do
    line = Keyword.get(meta, :line, 0)
    max(line, last)
  end

  defp _sigil?(name) do
    name
    |> Atom.to_string()
    |> String.starts_with?("sigil_")
  end

  defp _issue(issue_meta, meta) do
    issue_meta
    |> format_issue(
      message: "Multi-line function call without its first argument piped in",
      line_no: meta[:line]
    )
  end
end
