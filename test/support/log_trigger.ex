defmodule GraphConn.Test.LogTrigger do
  @moduledoc """
  A `:logger` handler that runs a function once, inside the calling test's own process, when that
  process logs a line containing a given text.

  A handler runs in the process that logs, so the function lands at exactly the point in the code
  under test where the line is logged: a message it sends arrives after everything before that line
  and before anything after it.
  """

  @doc """
  Runs `fun` in the calling process the `nth` time it logs a line containing `text`, until the
  calling test exits.
  """
  @spec attach(text :: String.t(), fun :: (-> any()), nth :: pos_integer()) :: :ok
  def attach(text, fun, nth \\ 1) when is_function(fun, 0) do
    handler_id = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    config = %{config: %{owner: self(), text: text, fun: fun, nth: nth}}
    :ok = :logger.add_handler(handler_id, __MODULE__, config)
    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(handler_id) end)
  end

  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{msg: {:string, chardata}}, %{id: handler_id, config: %{owner: owner} = config})
      when owner == self() do
    line = IO.chardata_to_string(chardata)

    if String.contains?(line, config.text) do
      seen_key = {__MODULE__, handler_id}
      seen = Process.get(seen_key, 0) + 1
      Process.put(seen_key, seen)
      if seen == config.nth, do: config.fun.()
    end

    :ok
  end

  def log(_other_event, _config),
    do: :ok
end
