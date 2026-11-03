defmodule GraphConn.GraphRestCallsTest do
  use ExUnit.Case, async: false
  import GraphConn.GraphRestCalls
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

  describe "authenticate/3" do
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
