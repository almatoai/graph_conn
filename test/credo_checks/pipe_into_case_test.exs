defmodule GraphConn.CredoChecks.PipeIntoCaseTest do
  use Credo.Test.Case

  alias GraphConn.CredoChecks.PipeIntoCase

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  describe "flags" do
    test "a local call as case's subject" do
      ~S'''
      defmodule M do
        def f(x) do
          case g(x) do
            _ -> :ok
          end
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeIntoCase)
      |> assert_issue(fn issue -> assert 3 == issue.line_no end)
    end

    test "a remote call as case's subject" do
      ~S'''
      defmodule M do
        def f(x) do
          case Map.get(x, :k) do
            _ -> :ok
          end
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeIntoCase)
      |> assert_issue(fn issue -> assert 3 == issue.line_no end)
    end

    test "a zero-arity call as case's subject" do
      ~S'''
      defmodule M do
        def f() do
          case g() do
            _ -> :ok
          end
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeIntoCase)
      |> assert_issue(fn issue -> assert 3 == issue.line_no end)
    end

    test "a pipe as case's subject" do
      ~S'''
      defmodule M do
        def f(x) do
          case x |> g() do
            _ -> :ok
          end
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeIntoCase)
      |> assert_issue(fn issue -> assert 3 == issue.line_no end)
    end
  end

  describe "allows" do
    test "piping into case" do
      ~S'''
      defmodule M do
        def f(x) do
          x
          |> g()
          |> case do
            _ -> :ok
          end
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeIntoCase)
      |> refute_issues()
    end

    test "a variable, literal or tuple subject" do
      ~S'''
      defmodule M do
        def f(x) do
          case {x, 1} do
            _ -> :ok
          end
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeIntoCase)
      |> refute_issues()
    end

    test "an operator subject" do
      ~S'''
      defmodule M do
        def f(x) do
          case x > 1 do
            _ -> :ok
          end
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeIntoCase)
      |> refute_issues()
    end

    test "field, bracket and attribute access subjects" do
      ~S'''
      defmodule M do
        def f(s) do
          case s.status do
            _ -> case(s[:k], do: (_ -> @x))
          end
        end
      end
      '''
      |> to_source_file()
      |> run_check(PipeIntoCase)
      |> refute_issues()
    end
  end
end
