defmodule GraphConn.CredoChecks.NoNestedCallTest do
  use Credo.Test.Case

  alias GraphConn.CredoChecks.NoNestedCall

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  describe "flags" do
    test "a local call as a local call's argument" do
      ~S'''
      defmodule M do
        def f(x), do: f(g(x))
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a call as a remote call's argument" do
      ~S'''
      defmodule M do
        def f(x), do: max(div(x, 4), 1)
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a call as an erlang call's argument" do
      ~S'''
      defmodule M do
        def f(x), do: :erlang.phash2(g(x))
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a call as a later argument" do
      ~S'''
      defmodule M do
        def f(o, k), do: Keyword.get(o, k, get_env(k))
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a zero-arity call as an argument" do
      ~S'''
      defmodule M do
        def f(), do: send(pid(), :connect)
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a call as a piped call's extra argument" do
      ~S'''
      defmodule M do
        def f(x), do: x |> Map.put(:k, g(x))
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "an anonymous function call as an argument" do
      ~S'''
      defmodule M do
        def f(fun, x), do: g(fun.(x))
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a call as an anonymous function call's argument" do
      ~S'''
      defmodule M do
        def f(fun, x), do: fun.(g(x))
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a call nested inside an interpolated call" do
      ~S'''
      defmodule M do
        def f(x), do: "#{length(g(x))}"
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a nested call inside a module attribute value" do
      ~S'''
      defmodule M do
        @value f(g(1))
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a nested call inside an assertion's expression" do
      ~S'''
      defmodule M do
        def f(x), do: if(x, do: f(g(x)))
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end
  end

  describe "allows" do
    test "a call as a tuple field value" do
      ~S'''
      defmodule M do
        def f(s), do: {:noreply, build(s)}
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "a call as a map and struct field value" do
      ~S'''
      defmodule M do
        def f(pid), do: {%{ref: Process.monitor(pid)}, %URI{host: host(pid)}}
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "a call as a list element and keyword value" do
      ~S'''
      defmodule M do
        def f(x), do: g([h(x)], timeout: t(x))
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "a call as an operator operand" do
      ~S'''
      defmodule M do
        def f(a, n), do: g(a * size(), n >= budget())
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "Kernel operators written as remote calls" do
      ~S'''
      defmodule M do
        def f(x), do: x |> Kernel.+(g(x))
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "any call interpolated into a string" do
      ~S'''
      defmodule M do
        def f(x), do: "#{inspect(x)} #{self()} #{length(x)} #{URI.encode_query(x)}"
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "self() as an argument" do
      ~S'''
      defmodule M do
        def f(delay), do: {send(self(), :x), Process.send_after(self(), :tick, delay)}
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "a plain variable as a single argument" do
      ~S'''
      defmodule M do
        def f(budget), do: step(budget)
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "field and bracket access as arguments" do
      ~S'''
      defmodule M do
        def f(s), do: g(s.base_name, s[:key])
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "module attributes, __MODULE__ and sigils as arguments" do
      ~S'''
      defmodule M do
        def f(), do: g(@x, __MODULE__, ~r/x/)
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "fn and captures as arguments" do
      ~S'''
      defmodule M do
        def f(l), do: Enum.map(l, &g(&1, 1)) |> Enum.map(fn x -> h(x) end)
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "macro forms taking code" do
      ~S'''
      defmodule M do
        def f(x) when is_map_key(x.a, :b) do
          if g(x) do
            case h(x) do
              _ -> assert g(x)
            end
          end
        end
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
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
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "typespecs" do
      ~S'''
      defmodule M do
        @spec f(name :: String.t()) :: map()
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end

    test "unquote inside quote" do
      ~S'''
      defmodule M do
        defmacro m(o), do: quote(do: Keyword.get(unquote(o), :k))
      end
      '''
      |> to_source_file()
      |> run_check(NoNestedCall)
      |> refute_issues()
    end
  end
end
