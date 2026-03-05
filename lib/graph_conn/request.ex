defmodule GraphConn.Request do
  @moduledoc """
  Structure of request used as a parameter in MyConn.execute/3.
  """

  alias __MODULE__, as: Request

  @type t() :: %Request{
          method: :get | :post | :put | :patch | :head | :options,
          headers: map(),
          path: String.t(),
          query_params: map(),
          body: nil | map() | String.t()
        }

  defstruct method: :get, path: "", query_params: %{}, body: nil, headers: %{}

  @doc """
  Normalizes the header names in the request to lowercase strings for consistent handling.
  """
  @spec normalize_headers(Request.t()) :: Request.t()
  def normalize_headers(%Request{headers: headers} = request),
    do: %Request{
      request
      | headers:
          Map.new(headers, fn {name, value} ->
            {_normalize_header_name(name), value}
          end)
    }

  defp _normalize_header_name(name) when is_atom(name),
    do: name |> to_string() |> String.downcase(:ascii)

  defp _normalize_header_name(name) when is_binary(name),
    do: String.downcase(name, :ascii)

  @doc """
  Prefixes the request path with the given namespace if not already present.
  """
  @spec set_namespace(Request.t(), String.t()) :: Request.t()
  def set_namespace(%Request{path: path} = request, namespace),
    do: %Request{request | path: namespace <> path}

  @doc """
  Sets the "authorization" header to "Bearer <token>" if the header is not already present, using
  the provided token.

  Does nothing if token is `nil`.
  """
  @spec set_default_auth(Request.t(), nil | String.t()) :: Request.t()
  def set_default_auth(%Request{} = request, nil),
    do: request

  def set_default_auth(%Request{headers: headers} = request, token),
    do: %Request{request | headers: Map.put_new(headers, "authorization", "Bearer " <> token)}

  @doc """
  Returns whether the request is authenticated on behalf of another entity by checking for the
  presence of an "authorization" header.

  Note that if this is called after `set_default_auth/2`, it will also return `true` for requests
  that are not actually on-behalf auth, but simply have a token set.
  """
  @spec on_behalf_auth?(Request.t()) :: boolean()
  def on_behalf_auth?(%Request{headers: headers}),
    do:
      Enum.any?(headers, fn {name, _value} -> _normalize_header_name(name) == "authorization" end)
end
