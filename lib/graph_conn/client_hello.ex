defmodule GraphConn.ClientHello do
  @moduledoc """
  Builds the `clientHello` frame an action-ws client sends after the server's `hello`.

  Configured per client, under the consumer's own `otp_app`, mirroring the frame:

  ```
  config :my_app, MyHandler,
    client_hello: [
      client: [app: "my-app", version: "1.2.3"],
      settings: [redelivery: true]
    ]
  ```

  Every key is optional. An unset key is left out of the frame, and a client that configures
  nothing sends no frame at all.
  """

  @sections [client: [:app, :version], settings: [:redelivery]]

  @doc "Returns the `clientHello` frame for `config`, or nil when there is nothing to send."
  @spec frame(config :: Keyword.t()) :: map() | nil
  def frame(config) do
    client_hello = Keyword.get(config, :client_hello, [])

    @sections
    |> Keyword.keys()
    |> Enum.reduce(%{type: "clientHello"}, &_put_section(&2, &1, client_hello))
    |> _nil_when_empty()
  end

  defp _put_section(frame, section, client_hello) do
    client_hello
    |> Keyword.get(section, [])
    |> case do
      [] -> frame
      values -> Map.put(frame, section, Map.new(values))
    end
  end

  defp _nil_when_empty(frame) when map_size(frame) == 1,
    do: nil

  defp _nil_when_empty(frame),
    do: frame

  @doc "Raises `ArgumentError` when `config`'s `:client_hello` is malformed."
  @spec validate!(config :: Keyword.t()) :: :ok
  def validate!(config) do
    client_hello =
      config
      |> Keyword.get(:client_hello, [])
      |> _keyword!(:client_hello, Keyword.keys(@sections))

    for {section, allowed} <- @sections do
      client_hello
      |> Keyword.get(section, [])
      |> _keyword!(section, allowed)
      |> Enum.each(fn {key, value} -> _value!(key, value) end)
    end

    :ok
  end

  defp _keyword!(value, name, allowed) do
    unless Keyword.keyword?(value),
      do: raise(ArgumentError, "#{inspect(name)} must be a keyword list, got: #{inspect(value)}")

    value
    |> Keyword.keys()
    |> Kernel.--(allowed)
    |> case do
      [] -> value
      unknown -> raise ArgumentError, "unknown keys #{inspect(unknown)} in #{inspect(name)}"
    end
  end

  defp _value!(:redelivery, value) when is_boolean(value),
    do: :ok

  defp _value!(key, value) when key in [:app, :version] and is_binary(value),
    do: :ok

  defp _value!(key, value),
    do: raise(ArgumentError, "invalid #{inspect(key)} in :client_hello: #{inspect(value)}")
end
