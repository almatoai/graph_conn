defmodule GraphConn.Features.VersionLookupTest do
  @moduledoc """
  Feature: Resolving an api version without touching the Graph

    As a consumer that only builds URLs from the Graph's api versions
    I want to ask for one api's version and have a missing one looked up again
    So that an api a restarting Graph left out becomes usable without a send or a socket.

  Background:
    Given a client started with `auto_connect: :just_versions`
    And a Graph whose first versions answer leaves out the `action` api
  """

  use ExUnit.Case, async: false

  @moduletag :feature

  alias GraphConn.{Mock, TestClient, TestConn}

  setup do
    TestClient.stop()
    TestClient.put_env(:retry_initial_ms, 20)

    cleanup = fn ->
      Mock.clear_rate_limit(:versions_omission)
      TestClient.stop()
    end

    on_exit(cleanup)

    :ok
  end

  describe "Scenario: asking for an api the first versions answer left out" do
    test "is told it is unknown, then gets its version once the versions are looked up again" do
      # Given the client picked up versions that lack `action`
      Mock.omit_versions_api("action", 2)
      assert {:ok, _sup_pid} = TestClient.start(auto_connect: :just_versions)
      assert_receive {:conn_status_changed, :got_api_versions}, 5_000

      manager = _manager_pid()
      :erlang.trace(manager, true, [:receive])

      # When the consumer asks for its version
      assert {:error, {:unknown_api, apis}} = GraphConn.version(TestConn, :action)

      # Then it is told the api is unknown, with the apis that are known
      refute :action in apis
      assert :auth in apis

      # And once the versions are looked up again on the retry curve, the api resolves
      assert_receive {:trace, ^manager, :receive, {:rediscover_versions, _next_in}}, 5_000
      _state = :sys.get_state(manager)

      assert {:ok, %{path: "/api/0.9/action/", protocol: ""}} =
               GraphConn.version(TestConn, :action)
    end
  end

  defp _manager_pid do
    TestConn
    |> Module.concat(ConnectionManager)
    |> Process.whereis()
  end
end
