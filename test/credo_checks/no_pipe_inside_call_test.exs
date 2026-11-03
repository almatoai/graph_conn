defmodule GraphConn.CredoChecks.NoPipeInsideCallTest do
  use Credo.Test.Case

  alias GraphConn.CredoChecks.NoPipeInsideCall

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  describe "flags" do
    test "a pipe as a local call argument" do
      ~S'''
      defmodule M do
        def f(x), do: foo(x |> bar(), 1)
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a pipe as a remote call argument" do
      ~S'''
      defmodule M do
        def f(x), do: Enum.map(x |> bar(), &baz/1)
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a pipe as an erlang module call argument" do
      ~S'''
      defmodule M do
        def f(x), do: :erlang.phash2(x |> bar())
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a pipe inside a call nested in a module attribute value" do
      ~S'''
      defmodule M do
        @value foo(:a |> bar())
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a pipe as a trailing keyword argument" do
      ~S'''
      defmodule M do
        def f(x), do: foo(x, timeout: x |> bar())
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a pipe as a block-named keyword argument without a do block" do
      ~S'''
      defmodule M do
        def f(x, y), do: foo(x, else: y |> bar())
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a pipe as an anonymous function call argument" do
      ~S'''
      defmodule M do
        def f(g, x), do: g.(x |> bar())
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a pipe as an argument of a call inside string interpolation" do
      ~S'''
      defmodule M do
        def f(x), do: "v #{foo(x |> bar())}"
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a pipe as an argument of a captured call" do
      ~S'''
      defmodule M do
        def f(x), do: Enum.map(x, &foo(&1 |> bar()))
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end
  end

  describe "does not flag" do
    for block <- ~w(else after rescue catch) do
      @block block
      test "a pipe as the body of a macro #{block} block" do
        """
        defmodule M do
          my_macro x do
            :ok
          #{@block}
            x |> bar()
          end
        end
        """
        |> to_source_file()
        |> run_check(NoPipeInsideCall)
        |> refute_issues()
      end
    end

    test "a pipe as a binary segment" do
      ~S'''
      defmodule M do
        def f(x), do: <<x |> bar()>>
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    test "a pipe as a map value" do
      ~S'''
      defmodule M do
        def f(x), do: %{a: x |> bar(), b: x |> bar()}
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    test "a pipe as a struct field" do
      ~S'''
      defmodule M do
        def f(x), do: %S{a: x |> bar()}
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    test "a pipe as a with clause right-hand side" do
      ~S'''
      defmodule M do
        def f(x) do
          with {:ok, y} <- x |> bar(), do: y
        end
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    test "a pipe as a for generator" do
      ~S'''
      defmodule M do
        def f(x), do: for(y <- x |> bar(), do: y)
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    test "a pipe as a 2-tuple element" do
      ~S'''
      defmodule M do
        def f(x), do: {:ok, x |> bar()}
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    test "a pipe as a 3-tuple element" do
      ~S'''
      defmodule M do
        def f(x), do: {:reply, x |> bar(), x}
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    test "a pipe as a list cons head" do
      ~S'''
      defmodule M do
        def f(x, rest), do: [x |> bar() | rest]
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    test "a pipe as the body of a macro do block" do
      ~S'''
      defmodule M do
        test "t" do
          x |> bar()
        end
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    for expression <- [
          ~S{"a" <> (x |> bar())},
          ~S{x..(y |> bar())},
          ~S{x =~ (y |> bar())},
          ~S{x ** (y |> bar())},
          ~S{x in (y |> bar())},
          ~S{x and (y |> bar())},
          ~S{x ||| (y |> bar())},
          ~S{x <<< (y |> bar())},
          ~S{x ~> (y |> bar())},
          ~S{x <|> (y |> bar())}
        ] do
      @expression expression
      test "a pipe as an operand of #{expression}" do
        """
        defmodule M do
          def f(x, y), do: #{@expression}
        end
        """
        |> to_source_file()
        |> run_check(NoPipeInsideCall)
        |> refute_issues()
      end
    end

    test "a pipe as a default argument" do
      ~S'''
      defmodule M do
        def f(x \\ :a |> bar()), do: x
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    test "a top-level pipe chain" do
      ~S'''
      defmodule M do
        def f(x), do: x |> bar() |> Enum.map(&baz/1)
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    test "a pipe inside string interpolation" do
      ~S'''
      defmodule M do
        def f(x), do: "value #{x |> bar()} here"
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    test "a module attribute set from a pipe" do
      ~S'''
      defmodule M do
        @sha :sha |> :crypto.hash(@script) |> Base.encode16()
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end

    test "a pipe bound to a variable" do
      ~S'''
      defmodule M do
        def f(x) do
          y = x |> bar()
          foo(y, 1)
        end
      end
      '''
      |> to_source_file()
      |> run_check(NoPipeInsideCall)
      |> refute_issues()
    end
  end
end
