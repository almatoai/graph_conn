defmodule GraphConn.GraphRestCalls do
  @moduledoc """
  Low-level REST calls against the connected Graph server.

  Provides `get_versions/1` (discovers available APIs at startup) and `execute/4`
  (issues an authenticated request against a specific API version). Used
  internally by `GraphConn.ConnectionManager`; not part of the public client
  API.
  """

  alias GraphConn.{Instrumenter, Request, Response, ResponseError, RetryAfter}
  require Logger

  @api_name_max 64
  @api_name ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,#{@api_name_max - 1}}\z/
  @logged_malformed 10

  @type versions() :: %{atom() => %{path: String.t(), subprotocol: String.t()}}

  @doc """
  Returns map of API versions connected Graph server supports,
  together with their path and subprotocol (for websocket connections).

  An answer that is not a JSON object, or names no well-formed entry, is
  `{:error, {:bad_versions, reason}}`; a malformed entry is skipped with a warning.

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
  @spec get_versions(base_name :: module(), config :: Keyword.t()) ::
          {:ok, versions()} | {:error, any()}
  def get_versions(base_name, config) do
    Logger.info("Getting supported Graph API versions...")

    request = %Request{path: "/api/version"}

    with {:ok, graph_versions} <- _get_versions(request, base_name, config),
         {:ok, auth_versions} <- _get_versions(request, base_name, config[:auth]) do
      auth_versions = Map.take(auth_versions, [:auth])

      {:ok, Map.merge(graph_versions, auth_versions)}
    end
  end

  @spec _get_versions(Request.t(), base_name :: module(), config :: Keyword.t()) ::
          {:ok, versions()} | {:error, any()}
  defp _get_versions(%Request{} = request, base_name, config) do
    request
    |> _shoot(base_name, config)
    |> case do
      %Finch.Response{status: 200, body: body} = response ->
        body
        |> Jason.decode()
        |> _versions(response)

      %Finch.Response{status: 429, headers: headers} ->
        RetryAfter.rate_limited(headers)

      %Finch.Response{status: status} = response ->
        _rejected(response, "has an unexpected status", {:unexpected_status, status})

      other ->
        Logger.error("#{inspect(other)}")
        {:error, other}
    end
  end

  # Only shape and size are logged: the body of a proxy page or a broken answer can be anything.
  defp _versions({:error, _decode_error}, response),
    do: _rejected(response, "is not JSON", {:bad_versions, :not_json})

  defp _versions({:ok, %{} = entries}, response) do
    {versions, malformed} =
      entries
      |> Enum.reduce({%{}, []}, &_take_entry/2)

    _warn_malformed(malformed)
    _usable_versions(versions, response)
  end

  defp _versions({:ok, _not_an_object}, response),
    do: _rejected(response, "is not a JSON object", {:bad_versions, :not_an_object})

  defp _take_entry(
         {key, %{"endpoint" => endpoint, "protocols" => protocol, "version" => version}},
         {versions, malformed}
       )
       when is_binary(endpoint) and is_binary(protocol) and is_binary(version) do
    key
    |> _api_atom()
    |> case do
      {:ok, api} ->
        entry = %{path: endpoint, protocol: protocol, subprotocol: version}
        {Map.put(versions, api, entry), malformed}

      :error ->
        {versions, [key | malformed]}
    end
  end

  defp _take_entry({key, _malformed_entry}, {versions, malformed}),
    do: {versions, [key | malformed]}

  defp _warn_malformed([] = _malformed),
    do: :ok

  defp _warn_malformed(malformed),
    do: Logger.warning(fn -> _malformed_message(malformed) end)

  # Bounded, since a broken answer can name any number of entries, each of any length.
  defp _malformed_message(malformed) do
    names =
      malformed
      |> Enum.sort()
      |> Enum.take(@logged_malformed)
      |> Enum.map_join(", ", &String.slice(&1, 0, @api_name_max))

    "Graph API versions: skipping malformed entries: #{names} (#{length(malformed)} in all)"
  end

  defp _usable_versions(versions, response) when map_size(versions) == 0,
    do: _rejected(response, "names no usable api", {:bad_versions, :no_usable_api})

  defp _usable_versions(versions, _response),
    do: {:ok, versions}

  defp _rejected(response, what, reason) do
    Logger.error(fn -> "Graph API versions answer #{what} (#{_described(response)})" end)
    {:error, reason}
  end

  defp _described(%Finch.Response{status: status, body: body, headers: headers}) do
    content_type =
      headers
      |> List.keyfind("content-type", 0)
      |> case do
        {_header, content_type} -> content_type
        nil -> "no content-type"
      end

    "#{status}, #{content_type}, #{byte_size(body)} bytes"
  end

  # Atoms are never collected, so only a name shaped like an api's becomes one.
  # sobelow_skip ["DOS.StringToAtom"]
  defp _api_atom(api_name) do
    if api_name =~ @api_name,
      do: {:ok, String.to_atom(api_name)},
      else: :error
  end

  @doc """
  Gets token for given `config`.

  - `expires_at` in response is unix time in milliseconds.
  """
  @spec authenticate(
          base_name :: module(),
          config :: Keyword.t(),
          apis :: %{atom() => %{atom() => String.t()}}
        ) :: {:ok, %{token: String.t(), expires_at: pos_integer()}} | {:error, any()}
  def authenticate(base_name, config, %{auth: %{path: auth_namespace}}) do
    Logger.info("Authenticating...")

    auth_config = Keyword.fetch!(config, :auth)
    timeout = Keyword.get(auth_config, :timeout, 60_000)

    body =
      auth_config
      |> Keyword.fetch!(:credentials)
      |> Enum.into(%{})
      |> Jason.encode!()

    %Request{method: :post, path: auth_namespace <> "app", body: body}
    |> _shoot(base_name, auth_config, timeout: timeout)
    |> case do
      %Finch.Response{status: 200, body: body} ->
        _auth_response(body)

      %Finch.Response{status: 401} ->
        Logger.error("401 received")
        {:error, :wrong_credentials}

      %Finch.Response{status: 429, headers: headers} ->
        RetryAfter.rate_limited(headers)

      %Finch.Response{body: body} = response ->
        error =
          body
          |> Jason.decode()
          |> case do
            {:ok, map} -> map
            {:error, _} -> response
          end

        Logger.error("Authentication error: #{inspect(error)}")
        {:error, error}

      %{reason: reason} ->
        Logger.error("Authentication error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Versions looked up while the graph was restarting can lack `auth`; the caller looks them up again.
  def authenticate(_base_name, _config, _apis),
    do: {:error, {:missing_api, :auth}}

  @spec execute(
          base_name :: module(),
          target_api :: atom(),
          Request.t(),
          opts :: Keyword.t()
        ) ::
          {:ok, Response.t()}
          | {:error, ResponseError.t()}
          | {:error, {:unknown_api, [any()]}}
  def execute(base_name, target_api, request, opts \\ []) do
    with {:ok, %{path: namespace}} <- _get_version(base_name, target_api) do
      [{:config, config}] = :ets.lookup(base_name, :config)

      token =
        base_name
        |> :ets.lookup(:token)
        |> case do
          [{:token, token}] -> token
          [] -> nil
        end

      request
      |> Request.normalize_headers()
      |> Request.set_namespace(namespace)
      |> Request.set_default_auth(token)
      |> _shoot(base_name, config, opts)
      |> _process_response()
    end
  end

  defp _get_version(_base_name, :base), do: {:ok, %{path: ""}}

  defp _get_version(base_name, target_api) do
    [{:versions, versions}] = :ets.lookup(base_name, :versions)

    versions
    |> Map.get(target_api)
    |> case do
      nil -> {:error, {:unknown_api, Map.keys(versions)}}
      version -> {:ok, version}
    end
  end

  defp _auth_response(body) do
    body
    |> Jason.decode()
    |> case do
      {:ok, decoded} -> _authenticated(decoded)
      {:error, _not_json} -> {:error, {:invalid_auth_response, :not_json}}
    end
  end

  defp _authenticated(%{"_TOKEN" => token, "expires-at" => expires_at}) do
    expires_at
    |> _expires_at()
    |> case do
      {:ok, expires_at} ->
        Logger.info("Successfully authenticated.")
        {:ok, %{token: token, expires_at: expires_at}}

      :error ->
        {:error, {:invalid_expires_at, expires_at}}
    end
  end

  # A `200` carrying a JSON error object rather than a token. A body that is not JSON at all never
  # reaches here -- the decode above answers it -- and both used to raise inside `ConnectionManager`.
  # Named by its fields alone: a body missing `expires-at` still carries the token.
  defp _authenticated(%{} = body),
    do: {:error, {:invalid_auth_response, Map.keys(body)}}

  defp _authenticated(_not_an_object),
    do: {:error, {:invalid_auth_response, :not_an_object}}

  # `Jason.decode!/1` hands back whatever the Graph sent, so the `pos_integer()` above is a promise
  # until it is checked here. Arithmetic on anything else raises inside `ConnectionManager`, which
  # takes the client's whole subtree with it.
  #
  # Only the TYPE is checked. A timestamp in the wrong unit, or one genuinely in the past, is a
  # valid integer and is paced by the refresh curve instead -- rejecting a past expiry here would
  # brick a client whose only fault is a skewed clock.
  defp _expires_at(expires_at) when is_integer(expires_at),
    do: {:ok, expires_at}

  # The same instant, written with a decimal point.
  defp _expires_at(expires_at) when is_float(expires_at),
    do: {:ok, trunc(expires_at)}

  defp _expires_at(_not_a_timestamp),
    do: :error

  defp _shoot(%Request{} = request, base_name, config, opts \\ []) do
    config_timeout = Keyword.get(config, :timeout, 5_000)
    timeout = Keyword.get(opts, :timeout, config_timeout)

    uri = _build_uri(request, config)

    body =
      case request.body do
        %{} -> Jason.encode!(request.body)
        nil -> ""
        body when is_binary(body) -> body
      end

    headers = _convert_headers(request.headers, body)

    log = fn ->
      method =
        request.method
        |> to_string()
        |> String.upcase()

      # Without the query, which can carry anything a caller put in it.
      uri_path = %URI{URI.parse(uri) | query: nil}
      "[GraphRestCaller] Sending #{method}: #{uri_path}"
    end

    Logger.debug(log)

    mono_start = System.monotonic_time()
    finch = GraphConn.Supervisor.finch_name(base_name)

    {_, response} =
      request.method
      |> Finch.build(uri, headers, body)
      |> Finch.request(finch, receive_timeout: timeout)

    instrument = fn ->
      durations = Instrumenter.durations(mono_start)
      body_received = Map.get(response, :body, "")

      measurements =
        %{
          time: DateTime.utc_now(),
          bytes_sent: byte_size(body),
          bytes_received: byte_size(body_received)
        }
        |> Map.merge(durations)

      metadata = %{
        node: Node.self(),
        path: request.path,
        method: request.method,
        status_code: Map.get(response, :status)
      }

      Instrumenter.execute(:rest, measurements, metadata)
    end

    spawn(instrument)

    response
  end

  defp _build_uri(%Request{path: path, query_params: query}, config) do
    transport = if config[:transport] == :tcp, do: "http", else: "https"
    "#{transport}://#{config[:host]}:#{config[:port]}#{path}?#{URI.encode_query(query)}"
  end

  @spec _convert_headers(headers :: map(), body :: String.t()) :: [
          {header_name :: String.t(), header_value :: String.t()}
        ]
  defp _convert_headers(headers, body) do
    json = "application/json"

    extras =
      if byte_size(body) > 0,
        do: %{"accept" => json, "content-type" => json},
        else: %{"accept" => json}

    headers
    |> Map.merge(extras)
    |> Enum.into([])
  end

  @spec _process_response(response :: Finch.Response.t() | map()) ::
          {:ok, Response.t()} | {:error, ResponseError.t()}
  defp _process_response(%Finch.Response{body: body} = response) do
    resp =
      body
      |> Jason.decode()
      |> case do
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
