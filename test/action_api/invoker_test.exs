defmodule GraphConn.ActionApi.InvokerTest do
  use ExUnit.Case, async: true

  describe "get_capabilities/0" do
    test "returns list of available capabilities" do
      _only_with_mock_server(fn ->
        assert Map.has_key?(ActionInvoker.available_capabilities(), "ExecuteCommand")
        refute Map.has_key?(ActionInvoker.available_capabilities(), "additional_capability")

        new_capabilities = """
        {"additional_capability" : {}}
        """

        assert :ok = GraphConn.Mock.put_capabilities(new_capabilities)

        ActionInvoker.reconfigure()

        assert Map.has_key?(ActionInvoker.available_capabilities(), "ExecuteCommand")
        assert Map.has_key?(ActionInvoker.available_capabilities(), "additional_capability")
      end)
    end
  end

  describe "get_applicabilities/0" do
    test "returns list of available applicabilities" do
      assert %{} = ActionInvoker.available_applicabilities()
    end
  end

  describe "capability_defaults/1" do
    test "returns defaults for known capability" do
      assert %{"timeout" => _} = ActionInvoker.capability_defaults("ExecuteCommand")
    end

    test "returns empty map for unknown capability" do
      assert %{} == ActionInvoker.capability_defaults("invalid_capability")
    end
  end

  describe "execute/4" do
    test "sends push message to ActionWS API and returns response synchronously" do
      params = %{"other_handler" => "Echo", "command" => "ls"}

      assert {:ok, %{"command" => "ls"}} =
               ActionInvoker.execute(UUID.uuid4(), _ah_id(), "ExecuteCommand", params)
    end

    @tag :integration
    test "invokes RunScript with success" do
      params = %{"command" => "ls", "host" => "localhost"}

      assert {:ok, response} = ActionInvoker.execute(UUID.uuid4(), _ah_id(), "RunScript", params)

      assert is_binary(response)
    end

    test "invokes RunScript with failure" do
      params = %{"command" => "failing_command", "host" => "localhost"}

      assert {:error, _req_id, "the command does not point to an existing file"} =
               ActionInvoker.execute(UUID.uuid4(), _ah_id(), "RunScript", params)
    end

    test "invokes HTTP with success" do
      _only_with_mock_server(fn ->
        params = %{
          method: "POST",
          url: "https://reqres.in/api/users",
          params: Jason.encode!(%{version: "t1"}),
          body: Jason.encode!(%{a: 1, b: "b", c: [%{aa: 11, bb: nil}]}),
          headers: "Content-Type=application/json\nAccept=application/json",
          insecure: "false"
        }

        assert {:ok, %{"body" => body, "code" => 201, "exec" => _}} =
                 ActionInvoker.execute(UUID.uuid4(), _ah_id(), "HTTP", params)

        assert %{
                 "a" => 1,
                 "b" => "b",
                 "c" => [%{"aa" => 11, "bb" => nil}]
               } = Jason.decode!(body)
      end)
    end

    test "injects default timeout when one is missing" do
      params = %{"other_handler" => "Echo", "command" => "ls"}

      assert {:ok, %{"other_handler" => "Echo", "command" => "ls", "timeout" => _}} =
               ActionInvoker.execute(UUID.uuid4(), _ah_id(), "ExecuteCommand", params)
    end

    test "doesn't inject default timeout if one is provided" do
      params = %{"other_handler" => "Echo", "command" => "ls", "timeout" => 123}

      assert {:ok, %{"command" => "ls", "timeout" => 123_000}} =
               ActionInvoker.execute(UUID.uuid4(), _ah_id(), "ExecuteCommand", params)
    end

    test "request understands atom keys" do
      params = %{other_handler: "Echo", command: "ls", timeout: 123}

      assert {:ok, %{"command" => "ls", "timeout" => 123_000}} =
               ActionInvoker.execute(UUID.uuid4(), _ah_id(), "ExecuteCommand", params)
    end

    test "returns nack for invalid capability" do
      assert {:error, _req_id,
              {:nack, %{code: 404, message: "capability invalid_capability not found"}}} =
               ActionInvoker.execute(UUID.uuid4(), _ah_id(), "invalid_capability", %{})
    end

    test "returns error if response has error key" do
      params = %{
        "other_handler" => "Echo",
        "return_error" => %{code: 404, message: "Error message"},
        "timeout" => 5
      }

      assert {:error, _req_id, %{"code" => 404, "message" => "Error message"}} =
               ActionInvoker.execute(UUID.uuid4(), _ah_id(), "ExecuteCommand", params)
    end

    test "actions can be executed in parallel" do
      timeout = 55
      params = %{"other_handler" => "Echo", "command" => "ls", "timeout" => timeout}
      test_pid = self()

      x = 5

      1..x
      |> Enum.reduce(%{}, fn n, acc ->
        req = UUID.uuid4()
        Process.sleep(1)

        # if Integer.mod(n, 349) == 0, do: spawn(fn -> _crash_connection() end)

        spawn(fn ->
          params =
            params
            |> Map.put("attempt", n)
            |> Map.put("req", req)

          assert {:ok, %{"command" => "ls", "attempt" => ^n, "req" => ^req}} =
                   ActionInvoker.execute(req, _ah_id(), "ExecuteCommand", params,
                     ack_timeout: timeout * 100
                   )

          send(test_pid, req)
        end)

        Map.put(acc, req, nil)
      end)
      |> Enum.each(fn {req, _} ->
        assert_receive(^req, timeout * 1_000)
      end)

      # for n <- 1..x do
      #  IO.inspect("Waiting for message #{n}")
      #  assert_receive(:done, 40_000)
      # end
    end

    test "retries sending request when ack timeout" do
      params = %{"other_handler" => "Echo", "command" => "ls"}

      assert {:ok, %{"command" => "ls"}} =
               ActionInvoker.execute(UUID.uuid4(), _ah_id(), "ExecuteCommand", params,
                 ack_timeout: 70
               )
    end

    ## These should test Handler and first one needs to be changed
    ## not to rely on log
    # test "handler returns cached result for the same request" do
    #  params = %{"other_handler" => "Echo", "command" => "ls", "timeout" => 3}
    #  ticket_id = UUID.uuid4()

    #  assert capture_log(fn ->
    #           assert {:ok, %{"command" => "ls"}} =
    #                    ActionInvoker.execute(ticket_id, _ah_id(), "ExecuteCommand", params)
    #         end) =~ ~r/Executing ExecuteCommand on/

    #  refute capture_log(fn ->
    #           assert {:ok, %{"command" => "ls"}} =
    #                    ActionInvoker.execute(ticket_id, _ah_id(), "ExecuteCommand", params,
    #                      timeout: 5_000
    #                    )
    #         end) =~ ~r/Executing ExecuteCommand on/
    # end

    # test "second request with the same id is sent before handler sends back response" do
    #  params = %{"other_handler" => "Echo", "command" => "ls", "sleep" => 100}
    #  ticket_id = UUID.uuid4()
    #  test_pid = self()

    #  spawn(fn ->
    #    assert {:ok, %{"command" => "ls"}} =
    #             ActionInvoker.execute(ticket_id, _ah_id(), "ExecuteCommand", params)

    #    send(test_pid, :done)
    #  end)

    #  assert {:ok, %{"command" => "ls"}} =
    #           ActionInvoker.execute(ticket_id, _ah_id(), "ExecuteCommand", params)

    #  assert_receive :done
    # end

    @tag :integration
    test "connection crashes after request is sent but before response is received" do
      params = %{"other_handler" => "Echo", "command" => "ls", "sleep" => 1000}
      ticket_id = UUID.uuid4()
      test_pid = self()

      spawn(fn ->
        assert {:ok, %{"command" => "ls"}} =
                 ActionInvoker.execute(ticket_id, _ah_id(), "ExecuteCommand", params)

        send(test_pid, :done)
      end)

      # Wait for ack to be recieved and then crash connection
      Process.sleep(200)
      _crash_connection()

      assert_receive :done
    end

    test "returns timeout if execution took too long" do
      params = %{other_handler: "Echo", command: "ls", sleep: 10_000, timeout: 1}

      assert {:error, _req_id, {:exec_timeout, 1_000}} =
               ActionInvoker.execute(UUID.uuid4(), _ah_id(), "ExecuteCommand", params)
    end
  end

  defp _ah_id do
    ActionInvoker.available_applicabilities()
    |> Map.keys()
    |> hd()
  end

  defp _crash_connection do
    # find :gun conn_pid
    [{_, ws_connection, _, _}] =
      ActionInvoker.WsConnections
      |> Process.whereis()
      |> Supervisor.which_children()

    %{conn_pid: gun_conn_pid} = :sys.get_state(ws_connection)
    assert Process.alive?(gun_conn_pid)

    # kill gun connection
    IO.puts("KILLING GUN CONNECTION")
    Process.exit(gun_conn_pid, :test_wants_you_dead)

    refute Process.alive?(gun_conn_pid)
  end

  defp _only_with_mock_server(fun) do
    if Process.whereis(GraphConn.Test.MockServer), do: fun.()
  end
end
