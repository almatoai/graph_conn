defmodule GraphConn.Mock do
  @moduledoc """
  In-process backing store for the mock Graph server.

  Holds capabilities and applicabilities used by the mock application in
  tests. Initial contents come from `:graph_conn, :mock` application env;
  tests can add to them at runtime via `put_capabilities/1` and
  `put_applicabilities/2`.
  """

  @default_token_lifetime 10 * 60 * 1_000

  @doc """
  Sets the lifetime the mock issues for `token`, in milliseconds.

  Scoped to one token on purpose: several clients share this mock, so a blanket override would
  change the token every one of them receives. A negative `lifetime_ms` issues a token that has
  already expired.
  """
  @spec put_token_lifetime(token :: String.t(), lifetime_ms :: integer()) :: :ok
  def put_token_lifetime(token, lifetime_ms) when is_binary(token) and is_integer(lifetime_ms) do
    :graph_conn
    |> Application.get_env(:mock_token_lifetimes, %{})
    |> Map.put(token, lifetime_ms)
    |> then(&Application.put_env(:graph_conn, :mock_token_lifetimes, &1))
  end

  @doc "Returns the lifetime the mock issues for `token`, in milliseconds. Ten minutes by default."
  @spec token_lifetime(token :: String.t()) :: integer()
  def token_lifetime(token) do
    :graph_conn
    |> Application.get_env(:mock_token_lifetimes, %{})
    |> Map.get(token, @default_token_lifetime)
  end

  @doc """
  Makes the mock issue `expires_at` verbatim for `token`, whatever its type.

  Scoped to one token for the same reason `put_token_lifetime/2` is. A Graph answering with a
  float, a string or anything else is what a `pos_integer()` spec cannot enforce on its own.
  `:absent` omits the field entirely, which is what a `200` carrying something other than a token
  looks like.
  """
  @spec put_expires_at(token :: String.t(), expires_at :: term()) :: :ok
  def put_expires_at(token, expires_at) when is_binary(token) do
    :graph_conn
    |> Application.get_env(:mock_expires_at, %{})
    |> Map.put(token, expires_at)
    |> then(&Application.put_env(:graph_conn, :mock_expires_at, &1))
  end

  @doc """
  Makes the mock answer `token`'s authentication with `body` verbatim, bypassing JSON encoding.

  A gateway in front of the Graph can answer `200` with an HTML error page, which is not a shape
  a JSON decoder can be handed.
  """
  @spec put_auth_body(token :: String.t(), body :: String.t()) :: :ok
  def put_auth_body(token, body) when is_binary(token) and is_binary(body) do
    :graph_conn
    |> Application.get_env(:mock_auth_bodies, %{})
    |> Map.put(token, body)
    |> then(&Application.put_env(:graph_conn, :mock_auth_bodies, &1))
  end

  @doc false
  @spec auth_body(token :: String.t()) :: String.t() | :from_identity
  def auth_body(token) do
    :graph_conn
    |> Application.get_env(:mock_auth_bodies, %{})
    |> Map.get(token, :from_identity)
  end

  @doc false
  @spec expires_at(token :: String.t()) :: term()
  def expires_at(token) do
    :graph_conn
    |> Application.get_env(:mock_expires_at, %{})
    |> Map.get(token, :from_lifetime)
    |> case do
      :from_lifetime -> _issued_expires_at(token)
      overridden -> overridden
    end
  end

  defp _issued_expires_at(token) do
    DateTime.utc_now()
    |> DateTime.to_unix(:millisecond)
    |> Kernel.+(token_lifetime(token))
  end

  @doc "Returns the currently configured capabilities map."
  @spec get_capabilities() :: map()
  def get_capabilities do
    Application.get_env(:graph_conn, :mock, [])[:capabilities] || %{}
  end

  @doc "Merges JSON-decoded `new_capabilities` into the stored capabilities."
  @spec put_capabilities(new_capabilities :: String.t()) :: :ok
  def put_capabilities(new_capabilities) when is_binary(new_capabilities) do
    capabilities = Map.merge(get_capabilities(), convert_capabilities_from_json(new_capabilities))

    mock =
      :graph_conn
      |> Application.get_env(:mock)
      |> Keyword.put(:capabilities, capabilities)

    Application.put_env(:graph_conn, :mock, mock)
  end

  @doc "Returns the currently configured applicabilities map keyed by handler id."
  @spec get_applicabilities() :: map()
  def get_applicabilities do
    Application.get_env(:graph_conn, :mock, [])[:applicabilities] || %{"action_handler" => %{}}
  end

  @doc """
  Puts `new_applicabilities` for action handler with "action_handler" id.
  """
  @spec put_applicabilities(ah_id :: String.t(), new_applicabilities :: String.t()) :: :ok
  def put_applicabilities(ah_id \\ "action_handler", new_applicabilities)
      when is_binary(new_applicabilities) do
    applicabilities =
      Map.merge(
        get_applicabilities()[ah_id],
        convert_applicabilities_from_json(new_applicabilities)
      )

    mock =
      :graph_conn
      |> Application.get_env(:mock)
      |> Keyword.put(:applicabilities, %{ah_id => applicabilities})

    Application.put_env(:graph_conn, :mock, mock)
  end

  @versions_key :versions
  @ws_upgrade_key :ws_upgrade
  @request_deny_key :request_deny

  @doc """
  Arms the mock to answer the next `times` authentication requests carrying `client_id`
  with a 429 advertising `retry_after_seconds`, or carrying no `retry-after` header at all
  when that is `:no_hint`.
  """
  @spec rate_limit_auth(
          client_id :: String.t(),
          times :: pos_integer(),
          retry_after_seconds :: pos_integer() | :no_hint
        ) :: :ok
  def rate_limit_auth(client_id, times, retry_after_seconds),
    do: _arm(client_id, times, retry_after_seconds)

  @doc """
  Arms the mock to answer the next `times` API-version lookups with a 429 advertising
  `retry_after_seconds`, or no `retry-after` header at all when that is `:no_hint`.

  Unlike `rate_limit_auth/3` this cannot be scoped to one client: `GET /api/version` carries no
  identity, so an arm here denies whichever suite asks next.
  """
  @spec rate_limit_versions(
          times :: pos_integer(),
          retry_after_seconds :: pos_integer() | :no_hint
        ) :: :ok
  def rate_limit_versions(times, retry_after_seconds),
    do: _arm(@versions_key, times, retry_after_seconds)

  defp _arm(key, times, payload) do
    true = :ets.insert(__MODULE__, {key, times, payload})
    :ok
  end

  @doc """
  Disarms any rate limit previously armed for `client_id`.

  Scoped to one client on purpose: a blanket reset would disarm whatever a concurrently
  running test had armed for a client of its own.
  """
  @spec clear_rate_limit(key :: String.t() | :versions | {:ws_upgrade, String.t()}) :: :ok
  def clear_rate_limit(key) do
    true = :ets.delete(__MODULE__, key)
    :ok
  end

  @doc false
  @spec take_auth_rate_limit(client_id :: String.t()) ::
          {:ok, retry_after_seconds :: pos_integer() | :no_hint} | :error
  def take_auth_rate_limit(client_id),
    do: _take_rate_limit(client_id)

  @doc false
  @spec take_versions_rate_limit() ::
          {:ok, retry_after_seconds :: pos_integer() | :no_hint} | :error
  def take_versions_rate_limit,
    do: _take_rate_limit(@versions_key)

  @doc """
  Arms the mock to answer the next `times` `action-ws` upgrades from `client_type` with `status`
  instead of a 101, advertising `retry_after_seconds` (or no `retry-after` header when that is
  `:no_hint`).

  `client_type` is the tail of the connecting client's `token-action_*` subprotocol, so an arm
  denies one client rather than whoever upgrades next.
  """
  @spec reject_ws_upgrade(
          client_type :: String.t(),
          times :: pos_integer(),
          status :: pos_integer(),
          retry_after_seconds :: pos_integer() | :no_hint
        ) :: :ok
  def reject_ws_upgrade(client_type, times, status, retry_after_seconds),
    do: _arm({@ws_upgrade_key, client_type}, times, {status, retry_after_seconds})

  @doc """
  Arms the mock to answer the next `times` `submitAction`s from `client_type` with an in-band
  rate-limit error advertising `retry_after_ms`, instead of acking them.

  The gateway answers a denied message on the open socket rather than closing it, so the client
  sees an error frame where it expected an ack.
  """
  @spec deny_next_request(
          client_type :: String.t(),
          times :: pos_integer(),
          retry_after_ms :: pos_integer()
        ) :: :ok
  def deny_next_request(client_type, times, retry_after_ms),
    do: _arm({@request_deny_key, client_type}, times, retry_after_ms)

  @doc false
  @spec take_request_denial(client_type :: String.t()) ::
          {:ok, retry_after_ms :: pos_integer()} | :error
  def take_request_denial(client_type),
    do: _take_rate_limit({@request_deny_key, client_type})

  @doc """
  Closes the socket held by `client_type` alone with `code` and `msg`.

  `1008` is what a gateway sends when it refuses the connection token itself, which a client must
  not answer by reconnecting with the same one.
  """
  @spec close_ws_connection(client_type :: String.t(), code :: pos_integer(), msg :: String.t()) ::
          :ok
  def close_ws_connection(client_type, code, msg) do
    Registry.TestSockets
    |> Registry.dispatch({:client, client_type}, fn entries ->
      for {pid, _registration} <- entries, do: send(pid, {:close, code, msg})
    end)
  end

  @doc false
  @spec take_ws_upgrade_rejection(client_type :: String.t()) ::
          {:ok, {status :: pos_integer(), retry_after_seconds :: pos_integer() | :no_hint}}
          | :error
  def take_ws_upgrade_rejection(client_type),
    do: _take_rate_limit({@ws_upgrade_key, client_type})

  defp _take_rate_limit(key) do
    __MODULE__
    |> :ets.whereis()
    |> case do
      :undefined -> :error
      _table -> _take_armed(key)
    end
  end

  # One atomic decrement, because two requests can take the same arm at once: a read-modify-write
  # over the count loses one of them and serves a 429 more than it was armed for.
  defp _take_armed(client_id) do
    absent = {client_id, 0, nil}

    __MODULE__
    |> :ets.update_counter(client_id, {2, -1, -1, -1}, absent)
    |> case do
      -1 -> :error
      _took_an_arm -> _armed_retry_after(client_id)
    end
  end

  defp _armed_retry_after(client_id) do
    __MODULE__
    |> :ets.lookup(client_id)
    |> case do
      [{^client_id, _remaining, payload}] -> {:ok, payload}
      [] -> :error
    end
  end

  @doc false
  @spec convert_capabilities_from_json(json :: String.t()) :: map()
  def convert_capabilities_from_json(json) do
    json
    |> Jason.decode!()
    |> Enum.map(fn {key, val} ->
      {mandatory_params, optional_params} =
        val
        |> Enum.reduce({%{}, %{}}, fn
          {param_name, nil}, {mandatory_params, optional_params} ->
            {Map.put(mandatory_params, param_name, %{}), optional_params}

          {param_name, default_value}, {mandatory_params, optional_params} ->
            {mandatory_params,
             Map.put(optional_params, param_name, %{"default" => default_value})}
        end)

      {key, %{"mandatoryParameters" => mandatory_params, "optionalParameters" => optional_params}}
    end)
    |> Enum.into(%{})
  end

  @doc false
  @spec convert_applicabilities_from_json(json :: String.t()) :: map()
  def convert_applicabilities_from_json(json) do
    json
    |> Jason.decode!()
    |> Enum.reduce(%{}, fn elem, acc ->
      capability = Map.get(elem, "capability")
      applicability_map = Map.get(elem, "applicability")

      {applicability_name, applicability_value} =
        case Enum.into(applicability_map, []) do
          [{applicability_name, applicability_value}] -> {applicability_name, applicability_value}
          [applicability_name] -> {applicability_name, %{}}
        end

      capability_value =
        acc
        |> Map.get(capability, %{})
        |> Map.put(applicability_name, applicability_value)

      Map.put(acc, capability, capability_value)
    end)
  end
end
