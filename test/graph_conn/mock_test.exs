defmodule GraphConn.MockTest do
  use ExUnit.Case, async: true
  alias GraphConn.Mock

  describe "capabilities" do
    test "returns default capabilities from config" do
      assert Application.get_env(:graph_conn, :mock)[:capabilities] == Mock.get_capabilities()
      refute Enum.empty?(Mock.get_capabilities())
    end

    test "returns default and added capabilities" do
      new_capabilities = """
      {"on_condition_test": {}}
      """

      assert :ok = Mock.put_capabilities(new_capabilities)
      assert %{"on_condition_test" => %{}} = Mock.get_capabilities()
      assert Enum.count(Mock.get_capabilities()) > 1
    end
  end

  describe "applicabilities" do
    test "returns default applicabilities from config" do
      assert %{"action_handler" => %{}} = Mock.get_applicabilities()
    end

    test "returns default and added applicabilities for action_handler" do
      refute Map.has_key?(Mock.get_applicabilities()["action_handler"], "ExecuteLocalCommand")

      new_applicabilities = """
      [
        {
          "name": "LocalHandler",
          "capability": "ExecuteLocalCommand",
          "implementation": "local",
          "applicability": ["on ogit/_id"],
          "exec": "${command}"
        }
      ]
      """

      assert :ok = Mock.put_applicabilities("action_handler", new_applicabilities)
      assert Map.has_key?(Mock.get_applicabilities()["action_handler"], "ExecuteLocalCommand")
    end
  end

  test "convert_capabilities_from_json" do
    json = """
    {
      "ExecuteCommand": {
        "timeout": 60000,
        "command": null
      }
    }
    """

    assert %{
             "ExecuteCommand" => %{
               "mandatoryParameters" => %{
                 "command" => %{}
               },
               "optionalParameters" => %{
                 "timeout" => %{"default" => 60_000}
               }
             }
           } == Mock.convert_capabilities_from_json(json)
  end

  test "convert_applicabilities_from_json" do
    json = """
    [
      {
        "name": "LocalHandler",
        "capability": "ExecuteLocalCommand",
        "implementation": "local",
        "applicability": {"on ogit/_id": {"LocalNodeID": "${ogit/_id}"}},
        "exec": "${command}"
      },
      {
        "name": "LocalHandler",
        "capability": "ExecuteLocalCommand",
        "implementation": "local",
        "applicability": {"on something_else": {"LocalNodeID": "something_else"}},
        "exec": "${command}"
      },
      {
        "name": "LocalHandler",
        "capability": "RunLocalScript",
        "implementation": "local",
        "applicability": ["on ogit/_id"],
        "tempfiles": {"tempfile": "${command}"},
        "exec": "sh -- ${tempfile}"
      }
    ]
    """

    assert %{
             "ExecuteLocalCommand" => %{
               "on ogit/_id" => %{
                 "LocalNodeID" => "${ogit/_id}"
               },
               "on something_else" => %{
                 "LocalNodeID" => "something_else"
               }
             },
             "RunLocalScript" => %{
               "on ogit/_id" => %{}
             }
           } == Mock.convert_applicabilities_from_json(json)
  end
end
