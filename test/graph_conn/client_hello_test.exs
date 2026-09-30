defmodule GraphConn.ClientHelloTest do
  use ExUnit.Case, async: true

  alias GraphConn.ClientHello

  describe "frame/1" do
    test "is nil when the client configures no client_hello" do
      assert nil == ClientHello.frame(url: "http://localhost:8081")
    end

    test "is nil when client_hello carries nothing to send" do
      assert nil == ClientHello.frame(client_hello: [])
      assert nil == ClientHello.frame(client_hello: [client: [], settings: []])
    end

    test "carries the client's app and version" do
      assert %{type: "clientHello", client: %{app: "my-app", version: "1.2.3"}} ==
               ClientHello.frame(client_hello: [client: [app: "my-app", version: "1.2.3"]])
    end

    test "leaves out a client field that is not set" do
      assert %{type: "clientHello", client: %{app: "my-app"}} ==
               ClientHello.frame(client_hello: [client: [app: "my-app"]])
    end

    test "carries settings without a client" do
      assert %{type: "clientHello", settings: %{redelivery: false}} ==
               ClientHello.frame(client_hello: [settings: [redelivery: false]])
    end

    test "carries client and settings together" do
      assert %{
               type: "clientHello",
               client: %{app: "my-app", version: "1.2.3"},
               settings: %{redelivery: true}
             } ==
               ClientHello.frame(
                 client_hello: [
                   client: [app: "my-app", version: "1.2.3"],
                   settings: [redelivery: true]
                 ]
               )
    end
  end

  describe "validate!/1" do
    test "accepts a client with no client_hello" do
      assert :ok == ClientHello.validate!(url: "http://localhost:8081")
    end

    test "accepts a complete client_hello" do
      assert :ok ==
               ClientHello.validate!(
                 client_hello: [
                   client: [app: "my-app", version: "1.2.3"],
                   settings: [redelivery: false]
                 ]
               )
    end

    test "refuses a client_hello that is not a keyword list" do
      assert_raise ArgumentError, ~r/client_hello/, fn ->
        ClientHello.validate!(client_hello: %{client: %{app: "my-app"}})
      end
    end

    test "refuses an app that is not a string" do
      assert_raise ArgumentError, ~r/:app/, fn ->
        ClientHello.validate!(client_hello: [client: [app: :my_app]])
      end
    end

    test "refuses a version that is not a string" do
      assert_raise ArgumentError, ~r/:version/, fn ->
        ClientHello.validate!(client_hello: [client: [version: 123]])
      end
    end

    test "refuses a redelivery that is not a boolean" do
      assert_raise ArgumentError, ~r/:redelivery/, fn ->
        ClientHello.validate!(client_hello: [settings: [redelivery: "false"]])
      end
    end

    test "refuses an unknown client key" do
      assert_raise ArgumentError, ~r/:name/, fn ->
        ClientHello.validate!(client_hello: [client: [name: "my-app"]])
      end
    end
  end
end
