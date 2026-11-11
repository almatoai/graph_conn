defmodule GraphConn.ActionApi.Invoker.RequestRegistryTest do
  use ExUnit.Case, async: true
  alias GraphConn.ActionApi.Invoker.RequestRegistry

  setup_all do
    {:ok, _pid} = RequestRegistry.Local.start_link(__MODULE__)
    :ok
  end

  describe ":ack message" do
    test "is received for registered request_id" do
      :ok = RequestRegistry.register(__MODULE__, "123")
      :ok = RequestRegistry.ack(__MODULE__, "123")
      assert_receive {:ack, "123"}
    end

    test "doesn't receive ack for message it's not registered with" do
      :ok = RequestRegistry.register(__MODULE__, "123")
      :ok = RequestRegistry.ack(__MODULE__, "234")
      refute_receive {:ack, "234"}
    end
  end

  describe ":nack message" do
    test "is received for registered request_id" do
      error = %{"code" => 403, "message" => "forbidden"}
      :ok = RequestRegistry.register(__MODULE__, "123")
      :ok = RequestRegistry.nack(__MODULE__, "123", error)
      assert_receive {:nack, "123", ^error}
    end

    test "doesn't receive ack for message it's not registered with" do
      error = %{"code" => 403, "message" => "forbidden"}
      :ok = RequestRegistry.register(__MODULE__, "123")
      :ok = RequestRegistry.nack(__MODULE__, "234", error)
      refute_receive {:nack, "234", _error}
    end

    @tag :skip
    test "is not received twice" do
      error = %{"code" => 403, "message" => "forbidden"}
      :ok = RequestRegistry.register(__MODULE__, "123")

      :ok = RequestRegistry.nack(__MODULE__, "123", error)
      assert_receive {:nack, "123", ^error}

      :ok = RequestRegistry.nack(__MODULE__, "123", error)
      refute_receive {:nack, "123", ^error}
    end
  end

  describe "refused/4" do
    test "sends a rate limit as {:rate_limited, id, ms}, which a node before 1.12.0 also reads" do
      :ok = RequestRegistry.register(__MODULE__, "123")
      :ok = RequestRegistry.refused(__MODULE__, "123", {:rate_limited, 1_986})
      assert_receive {:rate_limited, "123", 1_986}
    end

    test "sends any other refusal as {:refused, id, reason}" do
      error = %{"code" => 503, "message" => "Upstream unavailable"}
      :ok = RequestRegistry.register(__MODULE__, "123")
      :ok = RequestRegistry.refused(__MODULE__, "123", error)
      assert_receive {:refused, "123", ^error}
    end

    test "is :no_caller when nobody is registered for the request" do
      assert :no_caller == RequestRegistry.refused(__MODULE__, "456", {:rate_limited, 1_986})
    end
  end

  describe "rate_limited/4" do
    # Reached through the context: a call the compiler can resolve warns that it is deprecated.
    setup do
      %{registry: RequestRegistry}
    end

    test "still tells the caller to wait, as it did before refused/4", %{registry: registry} do
      :ok = RequestRegistry.register(__MODULE__, "123")
      assert :ok == registry.rate_limited(__MODULE__, "123", 1_986)
      assert_receive {:rate_limited, "123", 1_986}
    end
  end

  describe ":response message" do
    test "is received for registered request_id" do
      :ok = RequestRegistry.register(__MODULE__, "123")
      :ok = RequestRegistry.respond(__MODULE__, "123", %{a: 1})
      assert_receive {:response, "123", %{a: 1}}
    end

    test "doesn't receive response for message it's not registered with" do
      :ok = RequestRegistry.register(__MODULE__, "123")
      :ok = RequestRegistry.respond(__MODULE__, "234", %{a: 1})
      refute_receive {:response, "234", %{a: 1}}
    end

    @tag :skip
    test "is not received twice" do
      :ok = RequestRegistry.register(__MODULE__, "123")

      :ok = RequestRegistry.respond(__MODULE__, "123", %{a: 1})
      assert_receive {:response, "123", %{a: 1}}

      :ok = RequestRegistry.respond(__MODULE__, "123", %{a: 1})
      refute_receive {:response, "123", %{a: 1}}
    end
  end
end
