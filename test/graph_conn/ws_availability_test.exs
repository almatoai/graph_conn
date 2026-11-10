defmodule GraphConn.WSAvailabilityTest do
  use ExUnit.Case, async: true
  alias GraphConn.WS

  @missing_gun :graph_conn_test_no_such_gun

  describe "ensure_available!/1" do
    test "is :ok when gun is loadable" do
      assert :ok == WS.ensure_available!()
    end

    test "raises naming the dep to add when gun is not loadable" do
      error = assert_raise RuntimeError, fn -> WS.ensure_available!(@missing_gun) end

      assert error.message =~ ~s({:gun, "~> 2.1"})
      assert error.message =~ "WebSocket"
    end
  end

  describe "ensure_compilable!/2" do
    test "is :ok when gun is loadable" do
      assert :ok == WS.ensure_compilable!(__ENV__)
    end

    test "raises a CompileError at the using module when gun is not loadable" do
      env = __ENV__

      error = assert_raise CompileError, fn -> WS.ensure_compilable!(env, @missing_gun) end

      assert %CompileError{file: file, line: line, description: description} = error
      assert env.file == file
      assert env.line == line
      assert description =~ inspect(__MODULE__)
      assert description =~ ~s({:gun, "~> 2.1"})
    end
  end
end
