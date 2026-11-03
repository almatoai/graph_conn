defmodule GraphConn.CredoChecks.PipeMultilineCallTest do
  use Credo.Test.Case

  alias GraphConn.CredoChecks.PipeMultilineCall

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  describe "flags" do
    test "a multi-line local call" do
      ~S'''
      defmodule M do
        def f(vals, value) do
          reduce(vals, value, fn x, acc ->
            x + acc
          end)
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> assert_issue(fn issue -> assert 3 == issue.line_no end)
    end

    test "a multi-line remote call" do
      ~S'''
      defmodule M do
        def f(x) do
          Logger.warning(
            "a" <> x
          )
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> assert_issue(fn issue -> assert 3 == issue.line_no end)
    end

    test "a multi-line call whose only argument is an fn" do
      ~S'''
      defmodule M do
        def f() do
          on_exit(fn ->
            :ok
          end)
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> assert_issue(fn issue -> assert 3 == issue.line_no end)
    end

    test "a multi-line call without parentheses" do
      ~S'''
      defmodule M do
        def f(x) do
          raise ArgumentError,
            x
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> assert_issue(fn issue -> assert 3 == issue.line_no end)
    end

    test "a multi-line call on the left of a pipe" do
      ~S'''
      defmodule M do
        def f(x) do
          g(x,
            1)
          |> h()
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> assert_issue(fn issue -> assert 3 == issue.line_no end)
    end
  end

  describe "allows" do
    test "a single-line call" do
      ~S'''
      defmodule M do
        def f(x), do: g(x, 1)
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> refute_issues()
    end

    test "a piped multi-line call" do
      ~S'''
      defmodule M do
        def f(vals, value) do
          vals
          |> Enum.reduce(value, fn x, acc ->
            x + acc
          end)
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> refute_issues()
    end

    test "multi-line data literals and operators" do
      ~S'''
      defmodule M do
        def f(x) do
          {:ok,
           %{a: x,
             b: x}} ==
            x
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> refute_issues()
    end

    test "a multi-line function head" do
      ~S'''
      defmodule M do
        def f(
          a,
          b
        ), do: a + b
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> refute_issues()
    end

    test "macros taking code" do
      ~S'''
      defmodule M do
        describe "x" do
          test "y" do
            assert x ==
                     1
          end
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> refute_issues()
    end

    test "calls with a do block" do
      ~S'''
      defmodule M do
        get "/x" do
          f(conn)
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> refute_issues()
    end

    test "multi-line typespecs and attributes" do
      ~S'''
      defmodule M do
        @spec f(
          a :: map()
        ) :: map()
        @doc """
        x
        """
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> refute_issues()
    end

    test "a multi-line alias of several modules" do
      ~S'''
      defmodule M do
        alias GraphConn.{
          Backoff,
          ClientState
        }
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> refute_issues()
    end

    test "multi-line config" do
      ~S'''
      defmodule M do
        config :app, X,
          a: 1,
          b: 2
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> refute_issues()
    end

    test "a multi-line string interpolation" do
      ~S'''
      defmodule M do
        def f(x) do
          """
          #{x}
          """
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeMultilineCall)
      |> refute_issues()
    end
  end
end
