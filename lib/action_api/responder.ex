defmodule GraphConn.ActionApi.Responder do
  @moduledoc """
  Holds pending action responses keyed by request id.

  When the action-ws upstream takes longer than the caller's timeout, the
  invoker stores its `from` reference here so that a later upstream response
  can still be returned via `GenServer.reply/2`. Also handles resends after a
  delay when the connection drops mid-flight.
  """

  use GenServer
  require Logger

  @doc "Returns the registered process name of the responder for `base_name`."
  @spec name(base_name :: atom()) :: module()
  def name(base_name),
    do: Module.concat(base_name, Responder)

  @doc false
  @spec start_link(base_name :: atom()) :: GenServer.on_start()
  def start_link(base_name),
    do: GenServer.start_link(__MODULE__, base_name, name: name(base_name))

  @impl GenServer
  def init(base_name),
    do: {:ok, %{base_name: base_name, responses: %{}}}

  @doc """
  Sends `response` via action-ws and registers it for resend after `resend_after`
  ms in case the upstream doesn't ack.
  """
  @spec return_response(GraphConn.Request.t(), base_name :: atom(), resend_after :: pos_integer()) ::
          term()
  def return_response(%GraphConn.Request{} = response, base_name, resend_after) do
    base_name
    |> name()
    |> GenServer.cast({:register_response, response, resend_after})

    GraphConn.execute(base_name, :"action-ws", response)
  end

  @doc "Cancels any pending resend for `req_id` once it has been acked upstream."
  @spec response_acked(base_name :: module(), req_id :: String.t()) :: :ok
  def response_acked(base_name, req_id) do
    base_name
    |> name()
    |> GenServer.cast({:response_acked, req_id})
  end

  @impl GenServer
  def handle_cast(
        {:register_response, %GraphConn.Request{body: %{id: req_id}} = response, resend_after},
        state
      ) do
    responses =
      if Map.has_key?(state.responses, req_id) do
        state.responses
      else
        ref =
          state.base_name
          |> name()
          |> Process.send_after({:resend_response, req_id, resend_after}, resend_after)

        Map.put(state.responses, req_id, {response, ref})
      end

    {:noreply, %{state | responses: responses}}
  end

  def handle_cast({:response_acked, req_id}, state) do
    responses =
      state.responses
      |> Map.pop(req_id)
      |> case do
        {nil, responses} ->
          responses

        {{_, ref}, new_responses} ->
          Logger.info("[ActionHandler.Responder] Response acked", req_id: req_id)
          Process.cancel_timer(ref)
          new_responses
      end

    {:noreply, %{state | responses: responses}}
  end

  @impl GenServer
  def handle_info({:resend_response, req_id, resend_after}, state) do
    resend_after = resend_after * 2

    responses =
      if Map.has_key?(state.responses, req_id) do
        {%GraphConn.Request{} = response, _} = Map.get(state.responses, req_id)

        ref =
          state.base_name
          |> name()
          |> Process.send_after({:resend_response, req_id, resend_after}, resend_after)

        Logger.warning("[ActionHandler.Responder] Resending response", req_id: req_id)
        GraphConn.execute(state.base_name, :"action-ws", response)
        Map.put(state.responses, req_id, {response, ref})
      else
        state.responses
      end

    {:noreply, %{state | responses: responses}}
  end
end
