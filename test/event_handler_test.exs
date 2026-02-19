defmodule GraphConn.EventHandlerTest do
  use ExUnit.Case, async: false

  describe "status/0" do
    test "is :ready when ws connection is established" do
      assert :ready = GraphConn.Test.EventHandler.status()
    end
  end

  test "register and subscribe" do
    assert :ok = GraphConn.Test.EventHandler.register()
    assert :ok = GraphConn.Test.EventHandler.subscribe()
  end
end
