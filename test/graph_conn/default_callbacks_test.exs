defmodule GraphConn.DefaultCallbacksTest do
  use ExUnit.Case, async: false

  defmodule Plain do
    @moduledoc false
    use GraphConn, otp_app: :graph_conn
  end

  # The default callbacks only log at debug, so that is the level they can fail at.
  setup do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  test "the default main-connection callback takes a tuple status" do
    assert :ok == Plain.on_status_change({:disconnected, :started}, %{})
  end

  test "the default WebSocket callback takes a tuple status" do
    assert :ok ==
             Plain.on_status_change(
               :"action-ws",
               {:shutdown, "server sent close request: bye"},
               %{}
             )
  end
end
