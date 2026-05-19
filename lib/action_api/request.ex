defmodule GraphConn.ActionApi.Request do
  @moduledoc !"""
             Structure of request used for invoking action.
             """

  @type t() :: %__MODULE__{
          type: :submitAction,
          id: String.t(),
          handler: String.t(),
          capability: String.t(),
          timeout: pos_integer(),
          parameters: map()
        }

  @type build_params() :: %{
          optional(:timeout) => nil | pos_integer(),
          :ticket_id => String.t(),
          :handler => String.t(),
          :capability => String.t(),
          :params => map()
        }

  @derive Jason.Encoder
  @enforce_keys [:id, :handler, :capability, :timeout]
  defstruct type: :submitAction,
            id: nil,
            handler: nil,
            capability: nil,
            parameters: %{},
            timeout: 60_000

  @default_timeout 60_000

  @doc false
  @spec new(build_params()) :: t()
  def new(payload) do
    %__MODULE__{
      id: _calculate_id(payload),
      handler: payload.handler,
      capability: payload.capability,
      parameters: payload.params,
      timeout: payload[:timeout] || @default_timeout
    }
  end

  @doc false
  @spec _calculate_id(build_params()) :: String.t()
  def _calculate_id(payload) do
    term = {payload.ticket_id, payload.handler, payload.capability, payload.params}

    :md5
    |> :crypto.hash(:erlang.term_to_binary(term))
    |> Base.encode32(padding: false)
  end
end
