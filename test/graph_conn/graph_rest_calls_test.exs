defmodule GraphConn.GraphRestCallsTest do
  use ExUnit.Case, async: false
  import GraphConn.GraphRestCalls
  import ExUnit.CaptureLog, only: [with_log: 1]
  alias GraphConn.{ConnectionManager, Mock, TestConn}

  # Nothing listens on port 1, so a request sent there is refused at once.
  @closed_port 1

  # doctest GraphConn.GraphRestCalls

  describe "get_versions/1" do
    test "returns api versions" do
      config =
        :graph_conn
        |> Application.get_env(TestConn)
        |> ConnectionManager.parse_urls()

      assert {:ok, %{:"action-ws" => %{path: _, protocol: _, subprotocol: _}}} =
               get_versions(TestActionHandler, config)
    end

    test "reports the wait a rate-limiting graph advertised" do
      # The versions endpoint carries no client id, so this arm cannot be scoped the way the auth
      # and upgrade arms are. Containment rests on this module being `async: false`, so no other
      # module runs while the arm is up, plus `clear_rate_limit/1` in `on_exit`.
      on_exit(fn -> Mock.clear_rate_limit(:versions) end)
      Mock.rate_limit_versions(1, 2)

      config = _config("versions_rate_limited")
      assert {:error, {:rate_limited, 2_000}} == get_versions(TestActionHandler, config)
    end
  end

  describe "get_versions/2 from a graph that names no auth api" do
    setup do
      on_exit(fn -> Mock.clear_rate_limit(:versions_omission) end)
    end

    test "returns the versions it was given, without auth" do
      Mock.omit_versions_api("auth", 2)

      config = _config("versions_without_auth")
      assert {:ok, %{graph: _graph} = versions} = get_versions(TestActionHandler, config)
      refute is_map_key(versions, :auth)
    end

    test "takes auth from the auth url when only the main url leaves it out" do
      # The main url is asked first, so a single strip lands there.
      Mock.omit_versions_api("auth", 1)

      config = _config("versions_auth_from_auth_url")
      assert {:ok, %{auth: %{path: "/api/6/auth/"}}} = get_versions(TestActionHandler, config)
    end
  end

  describe "get_versions/2 from a graph answering with something other than versions" do
    setup do
      on_exit(fn -> Mock.clear_rate_limit(:versions_garble) end)
    end

    test "fails on a 200 that is not JSON, logging its size and type but not its body" do
      Mock.garble_versions(:html, 1)

      config = _config("versions_html")
      {result, log} = with_log(fn -> get_versions(TestActionHandler, config) end)

      assert {:error, {:bad_versions, :not_json}} == result
      assert log =~ "Graph API versions answer is not JSON (200, text/html"
      assert log =~ "51 bytes)"
      refute log =~ "proxy page"
    end

    test "fails on a 200 with a JSON array" do
      Mock.garble_versions(:array, 1)

      config = _config("versions_array")
      {result, log} = with_log(fn -> get_versions(TestActionHandler, config) end)

      assert {:error, {:bad_versions, :not_an_object}} == result
      assert log =~ "Graph API versions answer is not a JSON object (200, application/json"
      refute log =~ "endpoint"
    end

    test "skips a malformed entry with a warning naming it and keeps the others" do
      Mock.garble_versions({:malformed, "action"}, 2)

      config = _config("versions_one_malformed")
      {result, log} = with_log(fn -> get_versions(TestActionHandler, config) end)

      assert {:ok, %{graph: %{path: "/api/7.1/graph/"}, auth: _auth} = versions} = result
      refute is_map_key(versions, :action)
      assert log =~ "[warning] Graph API versions: skipping malformed entries: action"
    end

    test "fails when no entry is usable" do
      Mock.garble_versions({:malformed, :all}, 1)

      config = _config("versions_all_malformed")
      {result, log} = with_log(fn -> get_versions(TestActionHandler, config) end)

      assert {:error, {:bad_versions, :no_usable_api}} == result
      assert log =~ "Graph API versions answer names no usable api"
    end

    test "turns into an atom only the name of a well-formed entry" do
      malformed_name = "garbled_api_#{System.unique_integer([:positive])}"
      Mock.garble_versions({:extra, malformed_name, %{"endpoint" => "/api/1/x/"}}, 2)

      config = _config("versions_malformed_not_atomised")
      assert {:ok, %{graph: _graph}} = get_versions(TestActionHandler, config)

      assert_raise ArgumentError, fn -> String.to_existing_atom(malformed_name) end
    end

    test "skips an entry whose name is not an api name" do
      long_name = "api_#{System.unique_integer([:positive])}_" <> String.duplicate("x", 64)
      entry = %{"endpoint" => "/api/1/x/", "protocols" => "", "version" => "1"}
      Mock.garble_versions({:extra, long_name, entry}, 2)

      config = _config("versions_long_name")
      {result, log} = with_log(fn -> get_versions(TestActionHandler, config) end)

      assert {:ok, %{graph: _graph}} = result
      assert_raise ArgumentError, fn -> String.to_existing_atom(long_name) end
      shown = String.slice(long_name, 0, 64)
      assert log =~ "skipping malformed entries: #{shown} (1 in all)"
    end

    test "keeps an api name of 64 characters and skips one of 65" do
      prefix = "api_#{System.unique_integer([:positive])}_"
      longest = String.pad_trailing(prefix, 64, "x")
      too_long = String.pad_trailing(prefix, 65, "x")
      entry = %{"endpoint" => "/api/1/x/", "protocols" => "", "version" => "1"}
      config = _config("versions_name_boundary")

      Mock.garble_versions({:extra, longest, entry}, 2)
      assert {:ok, %{} = kept} = get_versions(TestActionHandler, config)
      longest_api = String.to_existing_atom(longest)
      assert is_map_key(kept, longest_api)

      Mock.garble_versions({:extra, too_long, entry}, 2)
      assert {:ok, %{graph: _graph}} = get_versions(TestActionHandler, config)
      assert_raise ArgumentError, fn -> String.to_existing_atom(too_long) end
    end

    test "names at most 10 malformed entries in its warning" do
      config = _config("versions_many_malformed")
      {:ok, versions} = get_versions(TestActionHandler, config)
      names = versions |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
      assert length(names) > 10, "the mock must serve more than 10 apis for the bound to show"

      Mock.garble_versions({:malformed, :all}, 1)
      {_result, log} = with_log(fn -> get_versions(TestActionHandler, config) end)

      first_ten = names |> Enum.take(10) |> Enum.join(", ")
      assert log =~ "skipping malformed entries: #{first_ten} (#{length(names)} in all)"
    end

    test "fails on any other status, logging its size and type but not its body" do
      Mock.garble_versions(:bad_gateway, 1)

      config = _config("versions_bad_gateway")
      {result, log} = with_log(fn -> get_versions(TestActionHandler, config) end)

      assert {:error, {:unexpected_status, 502}} == result
      assert log =~ "Graph API versions answer has an unexpected status (502, text/html"
      refute log =~ "proxy page"
    end
  end

  describe "authenticate/3" do
    test "returns an error naming the missing auth api when the versions have none" do
      config = _config("versions_without_auth")
      assert {:error, {:missing_api, :auth}} == authenticate(TestActionHandler, config, %{})
    end

    test "returns token" do
      config =
        :graph_conn
        |> Application.get_env(TestConn)
        |> ConnectionManager.parse_urls()

      {:ok, versions} = get_versions(TestActionHandler, config)

      assert {:ok, %{token: _, expires_at: _}} = authenticate(TestActionHandler, config, versions)
    end

    test "reports the wait a rate-limiting graph advertised" do
      # A client id of its own, so arming the mock can't deny anyone else's authentication.
      config = _config("rate_limited_client")
      {:ok, versions} = get_versions(TestActionHandler, config)
      _arm_rate_limit("rate_limited_client", 2)

      assert {:error, {:rate_limited, 2_000}} ==
               authenticate(TestActionHandler, config, versions)
    end

    test "reports a rate limit that advertised no wait at all" do
      config = _config("unhinted_rate_limited_client")
      {:ok, versions} = get_versions(TestActionHandler, config)
      _arm_rate_limit("unhinted_rate_limited_client", :no_hint)

      assert {:error, {:rate_limited, 0}} == authenticate(TestActionHandler, config, versions)
    end

    test "posts the token request to the auth url, not the main url" do
      config =
        :graph_conn
        |> Application.get_env(TestConn)
        |> ConnectionManager.parse_urls()

      {:ok, versions} = get_versions(TestActionHandler, config)
      main_down = Keyword.put(config, :port, @closed_port)

      assert {:ok, %{token: _token, expires_at: _expires_at}} =
               authenticate(TestActionHandler, main_down, versions)
    end

    test "fails when the auth url is down, even with the main url up" do
      config = _config("separate_auth_url_client")
      {:ok, versions} = get_versions(TestActionHandler, config)
      auth_down = Keyword.put(config[:auth], :port, @closed_port)
      config = Keyword.put(config, :auth, auth_down)

      assert {:error, :econnrefused} == authenticate(TestActionHandler, config, versions)
    end
  end

  defp _arm_rate_limit(client_id, retry_after_seconds) do
    on_exit(fn -> Mock.clear_rate_limit(client_id) end)
    Mock.rate_limit_auth(client_id, 1, retry_after_seconds)
  end

  defp _config(client_id) do
    config =
      :graph_conn
      |> Application.get_env(TestConn)
      |> ConnectionManager.parse_urls()

    credentials =
      config
      |> Keyword.fetch!(:auth)
      |> Keyword.fetch!(:credentials)
      |> Keyword.put(:client_id, client_id)

    auth = Keyword.put(config[:auth], :credentials, credentials)
    Keyword.put(config, :auth, auth)
  end
end
