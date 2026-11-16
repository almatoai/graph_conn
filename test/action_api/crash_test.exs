defmodule GraphConn.ActionApi.CrashTest do
  use ExUnit.Case, async: true

  alias GraphConn.ActionApi.Crash

  describe "banner/2" do
    test "keeps the message a capability raised itself" do
      assert "** (RuntimeError) capability blew up" ==
               Crash.banner(:error, %RuntimeError{message: "capability blew up"})
    end

    test "names any other exception by its module alone" do
      exception = %KeyError{key: "user", term: %{"password" => "s3cret"}}

      assert "** (KeyError)" == Crash.banner(:error, exception)
    end

    test "names a raw Erlang error by the exception it normalises to" do
      assert "** (FunctionClauseError)" == Crash.banner(:error, :function_clause)
    end

    test "keeps an exit or throw reason that is a string or an atom" do
      assert ~s[** (exit) "capability exited"] == Crash.banner(:exit, "capability exited")
      assert "** (exit) :killed" == Crash.banner(:exit, :killed)
      assert ~s[** (throw) "capability threw"] == Crash.banner(:throw, "capability threw")
    end

    test "leaves any other exit or throw reason out" do
      assert "** (exit)" == Crash.banner(:exit, {:shutdown, %{"password" => "s3cret"}})
      assert "** (throw)" == Crash.banner(:throw, %{"password" => "s3cret"})
    end

    test "names a crashed task's exception the way it names a raised one" do
      reason = {%KeyError{key: "user", term: %{"password" => "s3cret"}}, []}

      assert "** (KeyError)" == Crash.banner(:exit, reason)
    end
  end

  test "stays out of the API docs" do
    assert {:docs_v1, _anno, :elixir, _format, :hidden, _metadata, _docs} = Code.fetch_docs(Crash)
  end

  describe "format/3" do
    test "shows each stacktrace frame's arity, never its arguments" do
      stacktrace = [
        {Map, :fetch!, [%{"password" => "s3cret"}, "user"], [file: ~c"lib/map.ex", line: 1]}
      ]

      formatted = Crash.format(:error, :function_clause, stacktrace)

      assert formatted =~ "** (FunctionClauseError)"
      assert formatted =~ "Map.fetch!/2"
      refute formatted =~ "s3cret"
    end
  end
end
