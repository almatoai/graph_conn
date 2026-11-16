defmodule GraphConn.ActionApi.Crash do
  @moduledoc !"Describes a crashed action without the values it crashed on, which can be secrets."

  # Keeps a message only where the capability wrote it itself; otherwise the module or the kind.
  @doc false
  @spec banner(kind :: :error | :exit | :throw, reason :: term()) :: String.t()
  def banner(:error, %RuntimeError{message: message}),
    do: "** (RuntimeError) #{message}"

  def banner(:error, exception) when is_exception(exception),
    do: "** (#{inspect(exception.__struct__)})"

  def banner(:error, reason) do
    exception = Exception.normalize(:error, reason, [])
    banner(:error, exception)
  end

  def banner(:exit, {exception, _stacktrace}) when is_exception(exception),
    do: banner(:error, exception)

  def banner(kind, reason) when is_binary(reason) or is_atom(reason),
    do: "** (#{kind}) #{inspect(reason)}"

  def banner(kind, _reason),
    do: "** (#{kind})"

  @doc false
  @spec format(kind :: :error | :exit | :throw, reason :: term(), Exception.stacktrace()) ::
          String.t()
  def format(kind, reason, stacktrace) do
    frames =
      stacktrace
      |> Enum.map(&_without_args/1)
      |> Exception.format_stacktrace()

    "#{banner(kind, reason)}\n#{frames}"
  end

  defp _without_args({module, function, args, location}) when is_list(args),
    do: {module, function, length(args), location}

  defp _without_args({fun, args, location}) when is_list(args),
    do: {fun, length(args), location}

  defp _without_args(frame),
    do: frame
end
