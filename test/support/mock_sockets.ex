defmodule GraphConn.MockSockets do
  @moduledoc !"Finding the mock's side of the socket a test just opened, past any left by an earlier test."

  import ExUnit.Assertions, only: [flunk: 1]

  @doc "Returns the mock sockets registered for `client_type` right now."
  @spec registered(client_type :: String.t()) :: [pid()]
  def registered(client_type) do
    Registry.TestSockets
    |> Registry.lookup({:client, client_type})
    |> Enum.map(fn {socket, _registration} -> socket end)
  end

  @doc """
  Waits until a socket outside `known_sockets` registers for `client_type`, and returns it.

  The mock registers its side only once cowboy runs its init, after the client has seen the
  upgrade, and a socket from an earlier test can still be registered then. Take `known_sockets`
  with `registered/1` before opening the connection.
  """
  @spec await_new(client_type :: String.t(), known_sockets :: [pid()], deadline :: integer()) ::
          pid()
  def await_new(client_type, known_sockets, deadline) do
    client_type
    |> registered()
    |> Kernel.--(known_sockets)
    |> case do
      [socket | _others] ->
        socket

      [] ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("the mock never registered a new #{client_type} socket")

        Process.sleep(10)
        await_new(client_type, known_sockets, deadline)
    end
  end
end
