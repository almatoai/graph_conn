defmodule GraphConn.ClientStateTest do
  use ExUnit.Case, async: true

  alias GraphConn.ClientState

  setup do
    base_name = Module.concat(__MODULE__, "Client#{System.unique_integer([:positive])}")
    client_state = start_supervised!({ClientState, [base_name, %{count: 0}]})
    %{base_name: base_name, client_state: client_state}
  end

  describe "update_state/2" do
    test "stores the new state and replies with the function's reply", %{base_name: base_name} do
      increment = fn %{count: 0} = state -> {:was_zero, %{state | count: 1}} end

      assert :was_zero == ClientState.update_state(base_name, increment)

      assert %{count: 1} == ClientState.get_state(base_name)
    end

    test "loses no update when many processes update at once", %{base_name: base_name} do
      increment = fn state ->
        Process.sleep(1)
        {:ok, %{state | count: state.count + 1}}
      end

      1..50
      |> Enum.map(fn _update -> Task.async(fn -> _update(base_name, increment) end) end)
      |> Task.await_many()

      assert %{count: 50} == ClientState.get_state(base_name)
    end
  end

  describe "update_state/2 with a function that fails" do
    test "a raise fails only the caller and leaves the state as it was",
         %{base_name: base_name, client_state: client_state} do
      client_state_ref = Process.monitor(client_state)
      boom = fn _state -> raise "boom" end

      assert_raise RuntimeError, "boom", fn -> ClientState.update_state(base_name, boom) end
      assert %{count: 0} == ClientState.get_state(base_name)
      refute_received {:DOWN, ^client_state_ref, :process, _client_state, _reason}
    end

    test "a call back into ClientState fails only the caller",
         %{base_name: base_name, client_state: client_state} do
      client_state_ref = Process.monitor(client_state)
      reenter = fn state -> {ClientState.get_state(base_name), state} end

      assert {:calling_self, _call} =
               base_name
               |> ClientState.update_state(reenter)
               |> catch_exit()

      assert %{count: 0} == ClientState.get_state(base_name)
      refute_received {:DOWN, ^client_state_ref, :process, _client_state, _reason}
    end
  end

  defp _update(base_name, fun),
    do: ClientState.update_state(base_name, fun)
end
