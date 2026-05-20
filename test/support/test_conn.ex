defmodule GraphConn.TestConn do
  @moduledoc false

  use GraphConn, otp_app: :graph_conn

  @impl GraphConn
  @spec on_status_change(new_status :: atom(), internal_state :: map()) :: term()
  def on_status_change(new_status, %{forward_to: test_pid}) do
    send(test_pid, {:conn_status_changed, new_status})
  end

  @impl GraphConn
  @spec on_status_change(api :: atom(), new_status :: atom(), internal_state :: map()) :: term()
  def on_status_change(api, new_status, %{forward_to: test_pid}) do
    send(test_pid, {:conn_status_changed, api, new_status})
  end

  @impl GraphConn
  @spec handle_message(from_api :: atom(), msg :: term(), internal_state :: map()) :: term()
  def handle_message(from_api, msg, %{forward_to: test_pid}) do
    send(test_pid, {:received_message, from_api, msg})
  end
end
