defmodule GraphConn.Test.MockRouter do
  @moduledoc false

  use Plug.Router
  alias GraphConn.Mock
  alias GraphConn.Test.MockServer

  plug Plug.Logger

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug :match
  plug :dispatch

  @valid_token "action_invoker"
  @valid_handler_token "action_handler"
  @valid_standalone_token "action_standalone"

  get "/api/version" do
    GraphConn.Mock.take_versions_rate_limit()
    |> case do
      {:ok, retry_after_seconds} -> _rate_limited(conn, retry_after_seconds)
      :error -> _success(conn, _apis())
    end
  end

  get "/api/:_/action/app/:config_id/handlers" do
    _if_authorized(conn, fn ->
      body = [
        %{
          "ogit/_created-on" => 1_573_742_062_212,
          "ogit/_creator" => "ck2uexxlp005c5y38z00hbqhv_ck2uexyt9006r5y384wsfw2vp",
          "ogit/_creator-app" => "cju16o7cf0000mz77pbwbhl3q_cjix82tev000ou473gko8jgey",
          "ogit/_graphtype" => "vertex",
          "ogit/_id" => "ck2uexxlp005d5y38e5v8dif0_ck2yte2ro0pzbly38z0arl6vp",
          "ogit/_is-deleted" => false,
          "ogit/_modified-by" => "ck2uexxlp005c5y38z00hbqhv_ck2uexyt9006r5y384wsfw2vp",
          "ogit/_modified-by-app" => "cju16o7cf0000mz77pbwbhl3q_cjix82tev000ou473gko8jgey",
          "ogit/_modified-on" => 1_573_742_062_212,
          "ogit/_organization" => "ck2uexxlp005c5y38z00hbqhv_ck2uexxlp005g5y384b7ppurn",
          "ogit/_owner" => "ck2uexxlp005c5y38z00hbqhv_ck2uexxlp005e5y38fwcocvrf",
          "ogit/_scope" => "ck2uexxlp005c5y38z00hbqhv_ck2uexxlp005d5y38e5v8dif0",
          "ogit/_type" => "ogit/Automation/ActionHandler",
          "ogit/_v" => 1,
          "ogit/_v-id" => "1573742062212-Z597ml",
          "ogit/_xid" => "ogit/Automation/ActionHandler:SSH",
          "ogit/name" => "SSH"
        }
      ]

      _success(conn, body)
    end)
  end

  post "/api/:_/auth/app" do
    conn.params
    |> Map.get("client_id")
    |> GraphConn.Mock.take_auth_rate_limit()
    |> case do
      {:ok, retry_after_seconds} -> _rate_limited(conn, retry_after_seconds)
      :error -> _authenticate(conn)
    end
  end

  get "/api/:_/action/capabilities" do
    _success(conn, GraphConn.Mock.get_capabilities())
  end

  get "/api/:_/action/applicabilities" do
    _success(conn, GraphConn.Mock.get_applicabilities())
  end

  # Echos back collected map of request headers
  get "/api/:_/action/test-only/headers" do
    headers =
      conn.req_headers
      |> Enum.reduce(%{}, fn {name, value}, acc ->
        Map.update(acc, name, [value], fn values -> values ++ [value] end)
      end)

    _success(conn, headers)
  end

  defp _authenticate(conn) do
    config_credentials =
      MockServer.valid_invoker_credentials()
      |> Enum.map(fn {key, val} -> {to_string(key), val} end)
      |> Enum.into(%{})

    handler_credentials =
      MockServer.valid_handler_credentials()
      |> Enum.map(fn {key, val} -> {to_string(key), val} end)
      |> Enum.into(%{})

    event_handler_credentials =
      MockServer.valid_event_handler_credentials()
      |> Enum.map(fn {key, val} -> {to_string(key), val} end)
      |> Enum.into(%{})

    standalone_credentials =
      MockServer.valid_standalone_invoker_credentials()
      |> Enum.map(fn {key, val} -> {to_string(key), val} end)
      |> Enum.into(%{})

    case conn.params do
      ^config_credentials -> _success(conn, _credentials(@valid_token))
      ^handler_credentials -> _success(conn, _credentials(@valid_handler_token))
      ^event_handler_credentials -> _success(conn, _credentials(@valid_handler_token))
      ^standalone_credentials -> _success(conn, _credentials(@valid_standalone_token))
      _unknown_credentials -> _unauthorized(conn)
    end
  end

  defp _apis do
    %{
      "action" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/0.9/action/",
        "lifecycle" => "experimental",
        "protocols" => "",
        "specs" => "action",
        "support" => "supported",
        "version" => "0.9"
      },
      "action-ws" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/0.9/action-ws/",
        "lifecycle" => "experimental",
        "protocols" => "action-0.9.0",
        "specs" => "",
        "support" => "supported",
        "version" => "0.9"
      },
      "app" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/6.1/app/",
        "lifecycle" => "stable",
        "protocols" => "",
        "specs" => "app.yaml",
        "support" => "supported",
        "version" => "6.1"
      },
      "auth" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/6/auth/",
        "lifecycle" => "stable",
        "protocols" => "",
        "specs" => "auth.yaml",
        "support" => "supported",
        "version" => "6"
      },
      "authz" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/6.1/authz/",
        "lifecycle" => "stable",
        "protocols" => "",
        "specs" => "",
        "support" => "supported",
        "version" => "6.1"
      },
      "events-ws" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/6.1/events-ws/",
        "lifecycle" => "stable",
        "protocols" => "events-1.0.0",
        "specs" => "",
        "support" => "supported",
        "version" => "6.1"
      },
      "graph" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/7.1/graph/",
        "lifecycle" => "stable",
        "protocols" => "",
        "specs" => "api.yaml",
        "support" => "supported",
        "version" => "7.1"
      },
      "graph-ws" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/6.1/graph-ws/",
        "lifecycle" => "stable",
        "protocols" => "graph-2.0.0",
        "specs" => "",
        "support" => "supported",
        "version" => "6.1"
      },
      "health" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/7.0/health/",
        "lifecycle" => "stable",
        "protocols" => "",
        "specs" => "",
        "support" => "supported",
        "version" => "7.0"
      },
      "help" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/help/",
        "lifecycle" => "stable",
        "protocols" => "",
        "specs" => "",
        "support" => "supported",
        "version" => ""
      },
      "iam" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/6.1/iam/",
        "lifecycle" => "stable",
        "protocols" => "",
        "specs" => "iam.yaml",
        "support" => "supported",
        "version" => "6.1"
      },
      "ki" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/6/ki/",
        "lifecycle" => "stable",
        "protocols" => "",
        "specs" => "",
        "support" => "unsupported",
        "version" => "6"
      },
      "logs" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/0.9/logs/",
        "lifecycle" => "experimental",
        "protocols" => "",
        "specs" => "",
        "support" => "unsupported",
        "version" => "0.9"
      },
      "variables" => %{
        "docs" => "https://docs.hiro.arago.co/",
        "endpoint" => "/api/6/variables/",
        "lifecycle" => "stable",
        "protocols" => "",
        "specs" => "",
        "support" => "unsupported",
        "version" => "6"
      }
    }
  end

  defp _credentials(token) do
    token
    |> Mock.auth_body()
    |> case do
      :from_identity -> _identity_with_expiry(token)
      raw_body -> raw_body
    end
  end

  defp _identity_with_expiry(token) do
    identity = _identity(token)

    token
    |> Mock.expires_at()
    |> case do
      :absent -> identity
      expires_at -> Map.put(identity, "expires-at", expires_at)
    end
  end

  defp _identity(token) do
    %{
      "_APPLICATION" => "cju16o7cf0000mz77pbwbhl3q_cjix82tev000ou473gko8jgey",
      "_IDENTITY" => "engine1_main@customer1.org",
      "_IDENTITY_ID" => "ck2uexxlp005c5y38z00hbqhv_ck2uexyt9006r5y384wsfw2vp",
      "_TOKEN" => token,
      "type" => "Bearer"
    }
  end

  defp _if_authorized(conn, fun) do
    case :proplists.get_value("authorization", conn.req_headers) do
      "Bearer " <> @valid_token -> fun.()
      "Bearer " <> @valid_handler_token -> fun.()
      "Bearer " <> @valid_standalone_token -> fun.()
      _ -> _unauthorized(conn)
    end
  end

  defp _success(conn, body) when is_binary(body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, body)
  end

  defp _success(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  # Mirrors hiro-rate-limiter's reply: whole-second `retry-after` plus a JSON body.
  defp _rate_limited(conn, retry_after_seconds) do
    body = %{
      "error" => %{
        "code" => 429,
        "message" => "Too Many Requests",
        "from" => "rate-limiter"
      }
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> _put_retry_after(retry_after_seconds)
    |> Plug.Conn.send_resp(429, Jason.encode!(body))
  end

  defp _put_retry_after(conn, :no_hint),
    do: conn

  defp _put_retry_after(conn, retry_after_seconds),
    do: Plug.Conn.put_resp_header(conn, "retry-after", to_string(retry_after_seconds))

  defp _unauthorized(conn) do
    body = %{
      "error" => %{
        "code" => 400,
        "message" =>
          "Bad Request : {\"error_description\":\"Authentication failed for #{conn.params["username"]}\",\"error\":\"invalid_grant\"}"
      }
    }

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(401, Jason.encode!(body))
  end
end
