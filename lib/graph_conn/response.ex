defmodule GraphConn.Response do
  @moduledoc """
  Struct returned by successful REST calls: HTTP status code, response
  headers, and the decoded body.
  """

  @type t() :: %__MODULE__{
          code: pos_integer(),
          headers: GraphConn.headers(),
          body: nil | String.t() | map()
        }

  @enforce_keys ~w(code headers)a
  defstruct @enforce_keys ++ ~w(body)a
end
