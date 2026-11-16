defmodule GraphConn.CredoChecks.NoModuledocFalseTest do
  use Credo.Test.Case

  alias GraphConn.CredoChecks.NoModuledocFalse

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  describe "flags" do
    test "a module whose moduledoc is false" do
      ~S'''
      defmodule M do
        @moduledoc false
      end
      '''
      |> to_source_file()
      |> run_check(NoModuledocFalse)
      |> assert_issue(fn issue ->
        assert 2 == issue.line_no

        assert "`@moduledoc false`: write a one-line moduledoc, or `@moduledoc !\"...\"` to keep it private" ==
                 issue.message
      end)
    end

    test "a nested module whose moduledoc is false" do
      ~S'''
      defmodule M do
        @moduledoc "Outer."

        defmodule State do
          @moduledoc false
        end
      end
      '''
      |> to_source_file()
      |> run_check(NoModuledocFalse)
      |> assert_issue(fn issue -> assert 5 == issue.line_no end)
    end
  end

  describe "does not flag" do
    test "a one-line moduledoc" do
      ~S'''
      defmodule M do
        @moduledoc "Says what it is."
      end
      '''
      |> to_source_file()
      |> run_check(NoModuledocFalse)
      |> refute_issues()
    end

    test "a private moduledoc" do
      ~S'''
      defmodule M do
        @moduledoc !"Says what it is, privately."
      end
      '''
      |> to_source_file()
      |> run_check(NoModuledocFalse)
      |> refute_issues()
    end

    test "a function doc that is false" do
      ~S'''
      defmodule M do
        @moduledoc "Says what it is."

        @doc false
        def internal, do: :ok
      end
      '''
      |> to_source_file()
      |> run_check(NoModuledocFalse)
      |> refute_issues()
    end
  end
end
