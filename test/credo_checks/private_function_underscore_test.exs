defmodule GraphConn.CredoChecks.PrivateFunctionUnderscoreTest do
  use Credo.Test.Case

  alias GraphConn.CredoChecks.PrivateFunctionUnderscore

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  describe "flags" do
    test "a private function without a leading underscore" do
      ~S'''
      defmodule M do
        defp helper(x), do: x
      end
      '''
      |> to_source_file()
      |> run_check(PrivateFunctionUnderscore)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end

    test "a guarded private function without a leading underscore" do
      ~S'''
      defmodule M do
        defp helper(x) when is_integer(x), do: x
      end
      '''
      |> to_source_file()
      |> run_check(PrivateFunctionUnderscore)
      |> assert_issue(fn issue -> assert 2 == issue.line_no end)
    end
  end

  describe "does not flag" do
    test "a private function with a leading underscore" do
      ~S'''
      defmodule M do
        defp _helper(x), do: x
      end
      '''
      |> to_source_file()
      |> run_check(PrivateFunctionUnderscore)
      |> refute_issues()
    end

    test "a guarded private function with a leading underscore" do
      ~S'''
      defmodule M do
        defp _helper(x) when is_integer(x), do: x
      end
      '''
      |> to_source_file()
      |> run_check(PrivateFunctionUnderscore)
      |> refute_issues()
    end

    test "a public function without a leading underscore" do
      ~S'''
      defmodule M do
        def helper(x), do: x
      end
      '''
      |> to_source_file()
      |> run_check(PrivateFunctionUnderscore)
      |> refute_issues()
    end
  end
end
