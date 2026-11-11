defmodule GraphConn.ActionApi.Invoker.RequestRegistry do
  @moduledoc !"""
             Registry of `request_id` => `[calling_process]`. Each
             request invoker is registered here so it should expect
             `:ack` and `:response` messages sent back to it.
             """

  alias GraphConn.ActionApi.Invoker.RequestRegistry.Local, as: LocalRequestRegistry
  require Logger

  @doc "Returns the registered process name of the request registry for `base_name`."
  @spec name(base_name :: atom()) :: module()
  # Named after the client module with a fixed suffix: one atom per client, never input-driven.
  # sobelow_skip ["DOS.ModuleConcat"]
  def name(base_name),
    do: Module.concat(base_name, RequestRegistry)

  @callback register_self(registry :: atom(), key :: term()) :: :ok
  # `nil` when the request is not registered yet: a result for it is retried for up to 5s.
  @callback lookup(registry :: atom(), key :: term()) :: [pid()] | nil
  @callback unregister(registry :: atom(), key :: term()) :: :ok

  @doc """
  Registers calling process as requester for given `request_id`,
  meaning that it should expect `{:ack, request_id}` and
  `{:response, request_id, response, ack_response}` messages.
  """
  @spec register(base_name :: module(), request_id :: String.t(), registry :: module()) :: :ok
  def register(base_name, request_id, registry \\ LocalRequestRegistry) do
    base_name
    |> name()
    |> registry.register_self(request_id)
  end

  @doc "Removes the calling process from the registry for `request_id`."
  @spec unregister(base_name :: atom(), request_id :: String.t(), registry :: module()) :: :ok
  def unregister(base_name, request_id, registry \\ LocalRequestRegistry) do
    base_name
    |> name()
    |> registry.unregister(request_id)
  end

  @doc """
  Sends `{:ack, request_id}` messages to all process that registered
  themselves with `request_id`. This message is sent when Action API
  acks message on it's part.
  """
  @spec ack(base_name :: atom(), request_id :: String.t(), registry :: module()) :: :ok
  def ack(base_name, request_id, registry \\ LocalRequestRegistry) do
    base_name
    |> name()
    |> registry.lookup(request_id)
    |> List.wrap()
    |> Enum.each(fn pid -> send(pid, {:ack, request_id}) end)

    :ok
  end

  @doc """
  Tells every process registered for `request_id` that the request was refused.

  The gateway answers a refused request on the open socket instead of acking it, so the caller
  gets `reason` at once rather than timing out and resending into the same refusal. A rate limit
  is sent as `{:rate_limited, request_id, retry_after_ms}`, which a caller on a node before
  1.12.0 also reads; any other reason as `{:refused, request_id, reason}`.

  Returns `:no_caller` when nobody is registered for `request_id`.
  """
  @spec refused(
          base_name :: atom(),
          request_id :: String.t(),
          reason ::
            {:rate_limited, retry_after_ms :: non_neg_integer()}
            | GraphConn.ActionApi.error_frame(),
          registry :: module()
        ) :: :ok | :no_caller
  def refused(base_name, request_id, reason, registry \\ LocalRequestRegistry) do
    base_name
    |> name()
    |> registry.lookup(request_id)
    |> List.wrap()
    |> case do
      [] ->
        :no_caller

      pids ->
        message = _refusal(request_id, reason)
        Enum.each(pids, &send(&1, message))
    end
  end

  @doc """
  Sends `{:rate_limited, request_id, retry_after_ms}` to every process registered for
  `request_id`.
  """
  @deprecated "Use refused/4 with {:rate_limited, retry_after_ms} instead"
  @spec rate_limited(
          base_name :: atom(),
          request_id :: String.t(),
          retry_after_ms :: non_neg_integer(),
          registry :: module()
        ) :: :ok
  def rate_limited(base_name, request_id, retry_after_ms, registry \\ LocalRequestRegistry) do
    refused(base_name, request_id, {:rate_limited, retry_after_ms}, registry)
    :ok
  end

  defp _refusal(request_id, {:rate_limited, retry_after_ms}),
    do: {:rate_limited, request_id, retry_after_ms}

  defp _refusal(request_id, reason),
    do: {:refused, request_id, reason}

  @doc """
  Sends `{:nack, request_id, %{code: error_code, message: error_description}}`
  messages to all process that registered themselves with `request_id`.

  This message is sent when Action API nacks message on it's part.
  """
  @spec nack(
          base_name :: atom(),
          request_id :: String.t(),
          error :: term(),
          registry :: module()
        ) :: :ok
  def nack(base_name, request_id, error, registry \\ LocalRequestRegistry) do
    base_name
    |> name()
    |> registry.lookup(request_id)
    |> List.wrap()
    |> Enum.each(fn pid -> send(pid, {:nack, request_id, error}) end)

    :ok
  end

  @doc """
  Sends `{:response, request_id, response, ack_response}` messages to
  all process that registered themselves with `request_id`.
  """
  @spec respond(
          base_name :: atom(),
          request_id :: String.t(),
          response :: term(),
          registry :: module(),
          attempt :: pos_integer()
        ) :: :ok
  def respond(base_name, request_id, response, registry \\ LocalRequestRegistry, attempt \\ 1)

  def respond(_, request_id, _, _, 6),
    do:
      Logger.warning("Ignoring received response for unknown request id: #{inspect(request_id)}")

  def respond(base_name, request_id, response, registry, attempt) do
    base_name
    |> name()
    |> registry.lookup(request_id)
    |> case do
      nil ->
        :timer.sleep(1_000)
        respond(base_name, request_id, response, registry, attempt + 1)

      pids when is_list(pids) ->
        Enum.each(pids, fn pid -> send(pid, {:response, request_id, response}) end)
    end

    :ok
  end
end
