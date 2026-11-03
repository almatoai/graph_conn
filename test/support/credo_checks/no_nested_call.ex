defmodule GraphConn.CredoChecks.NoNestedCall do
  @moduledoc ~S"""
  Flags a function call passed directly as another call's argument, such as `f(g(x))` or
  `max(div(x, 4), 1)`.

  Allowed: `self()` as an argument anywhere (`send(self(), :x)`), a call as a field value of a
  data literal, a call as an operator operand, and any call interpolated into a string
  (`"#{f(x)}"`). Data literals are tuples, maps, structs, lists,
  keyword lists (so `foo(x, timeout: t())` passes) and binaries. A call nested inside an
  interpolated call (`"#{f(g(x))}"`) is still nested.

  Not treated as calls: operators, `fn`, `&` captures, `@attr`, `__MODULE__` and the other
  special forms, sigils, `unquote`, field access (`state.x`) and bracket access (`map[:k]`).

  Arguments that are not examined: those of definitions, control flow (`if`, `case`, `with`,
  ...), `use`/`import`/`alias`/`require`, ExUnit assertions and any call with a `do ... end`
  block, since those take code or conditions rather than values. Typespec attributes are
  skipped entirely. Calls inside all of these are still checked as calls of their own.
  """
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      Don't nest a call inside another call's arguments, even on one line. Pipe it or bind it:

          x |> div(4) |> max(1)

      or

          quarter = div(x, 4)
          max(quarter, 1)
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

  @not_calls ~w(
    fn & @ ^ {} %{} % <<>> __block__ __aliases__ __MODULE__ __ENV__ __CALLER__ __DIR__
    __STACKTRACE__ unquote unquote_splicing
  )a

  @typespec_attributes ~w(spec type typep opaque callback macrocallback)a

  @definitions ~w(def defp defmacro defmacrop defguard defguardp defdelegate)a

  @spec run(Credo.SourceFile.t(), params :: Keyword.t()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &_traverse(&1, &2, issue_meta))
  end

  defp _traverse({:@, _meta, [{attribute, _attribute_meta, _value}]}, issues, _issue_meta)
       when attribute in @typespec_attributes,
       do: {nil, issues}

  # `@name value` defines an attribute: only its value holds calls.
  defp _traverse({:@, meta, [{name, _name_meta, [value]}]}, issues, _issue_meta)
       when is_atom(name),
       do: {{:__block__, meta, [value]}, issues}

  # A function head is a pattern, not a call: only the body and options are walked.
  defp _traverse({definition, meta, [_head | rest]}, issues, _issue_meta)
       when definition in @definitions,
       do: {{:__block__, meta, rest}, issues}

  defp _traverse({{:., _dot_meta, [Kernel, :to_string]}, meta, [value]} = ast, issues, issue_meta) do
    meta
    |> Keyword.get(:from_interpolation, false)
    |> case do
      true -> {ast, issues}
      false -> {ast, _argument_issues([value], issue_meta) ++ issues}
    end
  end

  defp _traverse({_callee, _meta, args} = ast, issues, issue_meta) when is_list(args) do
    ast
    |> _outer_call?()
    |> case do
      true -> {ast, _argument_issues(args, issue_meta) ++ issues}
      false -> {ast, issues}
    end
  end

  defp _traverse(ast, issues, _issue_meta),
    do: {ast, issues}

  defp _argument_issues(args, issue_meta) do
    args
    |> Enum.filter(&_call?/1)
    |> Enum.map(&_issue(issue_meta, &1))
  end

  # A call whose own arguments are values, not a macro taking code.
  defp _outer_call?({name, meta, args}) when is_atom(name) do
    arity = length(args)

    not (name in @macro_forms or Macro.operator?(name, arity) or _sigil?(name) or
           Keyword.has_key?(meta, :do))
  end

  defp _outer_call?({{:., _dot_meta, _callee}, meta, _args} = ast),
    do: not (_access?(ast) or _kernel_operator?(ast) or Keyword.has_key?(meta, :do))

  defp _outer_call?(_ast),
    do: false

  # `self()` names the calling process; binding it first adds nothing.
  defp _call?({:self, _meta, []}),
    do: false

  defp _call?({name, _meta, args} = ast) when is_atom(name) and is_list(args) do
    arity = length(args)
    not (name in @not_calls or Macro.operator?(name, arity) or _sigil?(name) or _access?(ast))
  end

  defp _call?({{:., _dot_meta, _callee}, _meta, args} = ast) when is_list(args),
    do: not (_access?(ast) or _kernel_operator?(ast))

  defp _call?(_ast),
    do: false

  # `map[:key]` and `struct.field` read a value; they are not calls in the convention's sense.
  defp _access?({{:., _dot_meta, [Access, :get]}, meta, _args}),
    do: Keyword.get(meta, :from_brackets, false)

  defp _access?({{:., _dot_meta, [_receiver, field]}, meta, []}) when is_atom(field),
    do: Keyword.get(meta, :no_parens, false)

  # `Mod.{A, B}` in `alias` / `import` names modules; it is not a call.
  defp _access?({{:., _dot_meta, [_module, :{}]}, _meta, _args}),
    do: true

  defp _access?(_ast),
    do: false

  # `Kernel.+(x)` in a pipe is still an operator, so its operands are exempt like `a + b`'s.
  defp _kernel_operator?(
         {{:., _dot_meta, [{:__aliases__, _alias_meta, [:Kernel]}, name]}, _meta, args}
       ) do
    arity = length(args)
    Macro.operator?(name, arity)
  end

  defp _kernel_operator?(_ast),
    do: false

  defp _sigil?(name) do
    name
    |> Atom.to_string()
    |> String.starts_with?("sigil_")
  end

  defp _issue(issue_meta, {_callee, meta, _args}) do
    issue_meta
    |> format_issue(
      message: "Function call nested inside another call's arguments; pipe it or bind it",
      line_no: meta[:line]
    )
  end
end
