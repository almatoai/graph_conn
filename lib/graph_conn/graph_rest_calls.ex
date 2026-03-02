defmodule GraphConn.GraphRestCalls do
  alias GraphConn.{Request, Response, ResponseError, Instrumenter}
  require Logger

  @type versions() :: %{atom() => %{path: String.t(), subprotocol: String.t()}}

  @doc """
  Returns map of API versions connected Graph server supports,
  together with their path and subprotocol (for websocket connections).

  ## Example:

      iex> config = Application.get_env(:graph_conn, GraphConn.TestConn)
      iex> {:ok, _versions} = GraphConn.GraphRestCalls.get_versions(config)
      {:ok,
       %{
         action: %{path: "/api/0.9/action/", protocol: "", subprotocol: "0.9"},
         "action-ws": %{
           path: "/api/0.9/action-ws/",
           protocol: "action-0.9.0",
           subprotocol: "0.9"
         },
         app: %{path: "/api/6.1/app/", protocol: "", subprotocol: "6.1"},
         auth: %{path: "/api/6/auth/", protocol: "", subprotocol: "6"},
         authz: %{path: "/api/6.1/authz/", protocol: "", subprotocol: "6.1"},
         "events-ws": %{
           path: "/api/6.1/events-ws/",
           protocol: "events-1.0.0",
           subprotocol: "6.1"
         },
         graph: %{path: "/api/7.1/graph/", protocol: "", subprotocol: "7.1"},
         "graph-ws": %{
           path: "/api/6.1/graph-ws/",
           protocol: "graph-2.0.0",
           subprotocol: "6.1"
         },
         health: %{path: "/api/7.0/health/", protocol: "", subprotocol: "7.0"},
         help: %{path: "/help/", protocol: "", subprotocol: ""},
         iam: %{path: "/api/6.1/iam/", protocol: "", subprotocol: "6.1"},
         ki: %{path: "/api/6/ki/", protocol: "", subprotocol: "6"},
         logs: %{path: "/api/0.9/logs/", protocol: "", subprotocol: "0.9"},
         variables: %{path: "/api/6/variables/", protocol: "", subprotocol: "6"}
       }}
  """
  @spec get_versions(module(), Keyword.t()) :: {:ok, versions()} | {:error, any()}
  def get_versions(base_name, config) do
    Logger.info("Getting supported Graph API versions...")

    request = %Request{path: "/api/version"}

    with {:ok, graph_versions} <- _get_versions(request, base_name, config),
         {:ok, auth_versions} <- _get_versions(request, base_name, config[:auth]) do
      auth_versions = Map.take(auth_versions, [:auth])

      {:ok, Map.merge(graph_versions, auth_versions)}
    end
  end

  # we expect small and finite number of apis in versions response,
  # so it's safe to convert them to atoms
  # sobelow_skip ["DOS.StringToAtom"]
  @spec _get_versions(Request.t(), module(), Keyword.t()) :: {:ok, versions()} | {:error, any()}
  defp _get_versions(%Request{} = request, base_name, config) do
    request
    |> _shoot(base_name, config)
    |> case do
      %Finch.Response{status: 200, body: body} ->
        versions =
          body
          |> Jason.decode!()
          |> Enum.map(fn {key,
                          %{"endpoint" => endpoint, "protocols" => protocol, "version" => version}} ->
            {String.to_atom(key), %{path: endpoint, protocol: protocol, subprotocol: version}}
          end)
          |> Enum.into(%{})

        {:ok, versions}

      other ->
        Logger.error("#{inspect(other)}")
        {:error, other}
    end
  end

  @doc """
  Gets token for given `config`.

  - `expires_at` in response is unix time in milliseconds.
  """
  @spec authenticate(module(), Keyword.t(), %{atom() => %{atom() => String.t()}}) ::
          {:ok, %{token: String.t(), expires_at: pos_integer()}} | {:error, any()}
  def authenticate(base_bame, config, %{auth: %{path: auth_namespace}}) do
    Logger.info("Authenticating...")

    timeout =
      config
      |> Keyword.fetch!(:auth)
      |> Keyword.get(:timeout, 60_000)

    body =
      config
      |> Keyword.fetch!(:auth)
      |> Keyword.fetch!(:credentials)
      |> Enum.into(%{})
      |> Jason.encode!()

    %Request{method: :post, path: auth_namespace <> "app", body: body}
    |> _shoot(base_bame, config, timeout: timeout)
    |> case do
      %Finch.Response{status: 200, body: body} ->
        Logger.info("Successfully authenticated.")
        %{"_TOKEN" => token, "expires-at" => expires_at} = Jason.decode!(body)
        {:ok, %{token: token, expires_at: expires_at}}

      %Finch.Response{status: 401} ->
        Logger.error("401 received")
        {:error, :wrong_credentials}

      %Finch.Response{body: body} = response ->
        error =
          case Jason.decode(body) do
            {:ok, map} -> map
            {:error, _} -> response
          end

        Logger.error("Authentication error: #{inspect(error)}")
        {:error, error}

      %Finch.Error{reason: reason} ->
        Logger.error("Authentication error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def authenticate(_base_name, _config, apis) do
    {:error, "missing :auth key with :path in #{inspect(apis)}"}
  end

  @spec execute(module(), atom(), Request.t(), Keyword.t()) ::
          {:ok, Response.t()}
          | {:error, ResponseError.t()}
          | {:error, {:unknown_api, [any()]}}
  def execute(base_name, target_api, request, opts \\ []) do
    with {:ok, %{path: namespace}} <- _get_version(base_name, target_api) do
      [{:config, config}] = :ets.lookup(base_name, :config)

      token =
        case :ets.lookup(base_name, :token) do
          [{:token, token}] -> token
          [] -> nil
        end

      request
      |> _inject_namespace(namespace)
      |> _inject_token(token)
      |> _shoot(base_name, config, opts)
      |> _process_response()
    end
  end

  defp _get_version(_base_name, :base), do: {:ok, %{path: ""}}

  defp _get_version(base_name, target_api) do
    [{:versions, versions}] = :ets.lookup(base_name, :versions)

    case Map.get(versions, target_api) do
      nil -> {:error, {:unknown_api, Map.keys(versions)}}
      version -> {:ok, version}
    end
  end

  @spec _inject_namespace(Request.t(), String.t()) :: Request.t()
  defp _inject_namespace(%Request{path: path} = request, namespace),
    do: %Request{request | path: namespace <> path}

  @spec _inject_token(Request.t(), nil | String.t()) :: Request.t()
  defp _inject_token(%Request{} = request, nil),
    do: request

  defp _inject_token(%Request{headers: headers} = request, token),
    do: %Request{request | headers: Map.put_new(headers, "Authorization", "Bearer " <> token)}

  defp _shoot(%Request{} = request, base_name, config, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Keyword.get(config, :timeout, 5_000))

    uri = _build_uri(request, config)

    body =
      case request.body do
        %{} -> Jason.encode!(request.body)
        nil -> ""
        body when is_binary(body) -> body
      end

    headers = _convert_headers(request.headers, body)

    Logger.debug(fn ->
      "[GraphRestCaller] Sending #{String.upcase(to_string(request.method))}: #{uri}"
    end)

    mono_start = System.monotonic_time()

    {_, response} =
      request.method
      |> Finch.build(uri, headers, body)
      |> Finch.request(Module.concat(base_name, Finch), receive_timeout: timeout)

    spawn(fn ->
      Instrumenter.execute(
        :rest,
        %{
          time: DateTime.utc_now(),
          duration: Instrumenter.duration(mono_start),
          bytes_sent: byte_size(body),
          bytes_received: byte_size(Map.get(response, :body, ""))
        },
        %{
          node: Node.self(),
          path: request.path,
          method: request.method,
          status_code: Map.get(response, :status)
        }
      )
    end)

    response
  end

  defp _build_uri(%Request{path: path, query_params: query}, config) do
    transport = if config[:transport] == :tcp, do: "http", else: "https"
    "#{transport}://#{config[:host]}:#{config[:port]}#{path}?#{URI.encode_query(query)}"
  end

  @spec _convert_headers(map(), String.t()) :: [
          {header_name :: String.t(), header_value :: String.t()}
        ]
  defp _convert_headers(headers, body) do
    json = "application/json"

    if byte_size(body) > 0 do
      headers
      |> Map.merge(%{
        "accept" => json,
        "content-type" => json
      })
    else
      headers
      |> Map.merge(%{
        "accept" => json
      })
    end
    |> Enum.into([])
  end

  @spec _process_response(Finch.Response.t() | map()) ::
          {:ok, Response.t()} | {:error, ResponseError.t()}
  defp _process_response(%Finch.Response{body: body} = response) do
    resp =
      case Jason.decode(body) do
        {:ok, result} -> %{response | body: result}
        _ -> response
      end

    response = %Response{
      code: resp.status,
      body: resp.body,
      headers: resp.headers
    }

    {:ok, response}
  end

  defp _process_response(%{reason: reason} = response) do
    Logger.warning("[GraphRestCalls] Received: #{inspect(response)}")
    {:error, %ResponseError{reason: inspect(reason)}}
  end

  defp _process_response(error) do
    Logger.error("[GraphRestCalls] Received unhandled REST response: #{inspect(error)}")
    {:error, %ResponseError{error: error}}
  end
end
