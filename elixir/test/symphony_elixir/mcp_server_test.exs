defmodule SymphonyElixir.McpServerTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest

  alias SymphonyElixir.Mcp.Server

  @endpoint SymphonyElixirWeb.Endpoint

  @tool_spec %{
    "name" => "github_api",
    "description" => "Call the GitHub REST API.",
    "inputSchema" => %{"type" => "object", "properties" => %{"method" => %{"type" => "string"}}}
  }

  defp tools(specs \\ [@tool_spec]), do: %{tool_specs: specs}

  describe "handshake" do
    test "answers initialize with a protocol version and tool capability" do
      assert {:reply, response} = Server.handle(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})

      assert response["id"] == 1
      assert response["jsonrpc"] == "2.0"
      assert response["result"]["protocolVersion"] == "2025-06-18"
      assert response["result"]["capabilities"]["tools"]
      assert response["result"]["serverInfo"]["name"] == "symphony-tracker"
    end

    test "never answers a notification, which carries no id" do
      assert :noreply = Server.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      assert :noreply = Server.handle(%{"jsonrpc" => "2.0", "method" => "notifications/cancelled"})
    end
  end

  describe "tools/list" do
    test "publishes the tracker's own specs unchanged" do
      assert {:reply, response} =
               Server.handle(%{"id" => 2, "method" => "tools/list"}, binding: tools())

      assert [tool] = response["result"]["tools"]
      assert tool["name"] == "github_api"
      assert tool["description"] == "Call the GitHub REST API."
      assert tool["inputSchema"] == @tool_spec["inputSchema"]
    end

    test "supplies an object schema for a tool that declares none" do
      specs = [%{"name" => "bare"}]

      assert {:reply, response} =
               Server.handle(%{"id" => 3, "method" => "tools/list"}, binding: tools(specs))

      assert [tool] = response["result"]["tools"]
      assert tool["inputSchema"] == %{"type" => "object"}
      assert tool["description"] == ""
    end
  end

  describe "tools/call" do
    test "translates a tracker success into MCP content" do
      executor = fn "github_api", %{"method" => "GET"} ->
        %{"success" => true, "output" => "{}", "contentItems" => [%{"type" => "inputText", "text" => "{}"}]}
      end

      request = %{
        "id" => 4,
        "method" => "tools/call",
        "params" => %{"name" => "github_api", "arguments" => %{"method" => "GET"}}
      }

      assert {:reply, response} = Server.handle(request, binding: tools(), executor: executor)

      assert response["result"]["content"] == [%{"type" => "text", "text" => "{}"}]
      refute response["result"]["isError"]
    end

    test "marks a failed tracker call as an MCP error without raising" do
      executor = fn _tool, _args ->
        %{"success" => false, "output" => "boom", "contentItems" => [%{"type" => "inputText", "text" => "boom"}]}
      end

      request = %{"id" => 5, "method" => "tools/call", "params" => %{"name" => "github_api"}}

      assert {:reply, response} = Server.handle(request, binding: tools(), executor: executor)

      assert response["result"]["isError"]
      assert response["result"]["content"] == [%{"type" => "text", "text" => "boom"}]
    end

    test "rejects a call naming no tool" do
      assert {:reply, response} =
               Server.handle(%{"id" => 6, "method" => "tools/call", "params" => %{}},
                 binding: tools()
               )

      assert response["error"]["code"] == -32_602
    end
  end

  describe "protocol errors" do
    test "reports an unsupported method against its id" do
      assert {:reply, response} = Server.handle(%{"id" => 7, "method" => "resources/list"})

      assert response["error"]["code"] == -32_601
      assert response["error"]["message"] =~ "resources/list"
    end

    test "rejects a request carrying no method" do
      assert {:reply, response} = Server.handle(%{"id" => 8})
      assert response["error"]["code"] == -32_600
    end
  end

  describe "streamable-HTTP transport" do
    test "answers a stream probe with 405 and an allow header, not 404" do
      start_test_endpoint()

      conn = get(build_conn(), "/mcp")

      # 404 would tell the client it had the wrong URL and invite a retry
      # against another path; 405 says the endpoint exists and offers no stream.
      assert conn.status == 405
      assert Plug.Conn.get_resp_header(conn, "allow") == ["POST"]
    end

    test "still serves JSON-RPC over POST" do
      start_test_endpoint()

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 9, "method" => "initialize"}))

      assert json_response(conn, 200)["result"]["serverInfo"]["name"] == "symphony-tracker"
    end
  end

  describe "registration" do
    test "describes itself as a remote MCP server for an opencode instance" do
      config = Server.remote_config("http://127.0.0.1:4000/mcp")

      assert config["type"] == "remote"
      assert config["url"] == "http://127.0.0.1:4000/mcp"
      assert config["enabled"]
      refute Map.has_key?(config, "headers")

      with_headers = Server.remote_config("http://x/mcp", headers: %{"authorization" => "Bearer t"})
      assert with_headers["headers"] == %{"authorization" => "Bearer t"}
    end
  end

  defp start_test_endpoint do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end
end
