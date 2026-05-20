defmodule GraphConn.EventHandlerTest do
  use ExUnit.Case, async: false
  alias GraphConn.Test.EventHandler

  describe "status/0" do
    test "is :ready when ws connection is established" do
      assert :ready = EventHandler.status()
    end
  end

  test "register and subscribe" do
    assert :ok = EventHandler.register()
    assert :ok = EventHandler.subscribe()
  end
end
