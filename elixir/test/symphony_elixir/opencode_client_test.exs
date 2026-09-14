defmodule SymphonyElixir.OpencodeClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Opencode.Client

  describe "HTTP transport" do
    test "sends each endpoint's documented request shape and accepts its response type" do
      {base_url, server} =
        start_server([
          json_response(%{"id" => "ses_abc"}),
          json_response(%{"info" => %{"role" => "assistant"}}),
          json_response(%{"registered" => true}),
          json_response(true),
          json_response(true),
          json_response(%{"healthy" => true})
        ])

      opts = [password: "secret", username: "operator"]

      assert {:ok, %{"id" => "ses_abc"}} =
               Client.create_session(base_url, "/workspaces/GH-1", title: "GH-1", password: "secret", username: "operator")

      assert_request("POST /session?directory=%2Fworkspaces%2FGH-1 HTTP/1.1", %{"title" => "GH-1"}, opts)

      assert {:ok, %{"info" => %{"role" => "assistant"}}} =
               Client.send_message(base_url, "ses_abc", %{"parts" => [%{"type" => "text", "text" => "Ship it"}]}, opts)

      assert_request("POST /session/ses_abc/message HTTP/1.1", %{"parts" => [%{"type" => "text", "text" => "Ship it"}]}, opts)

      assert {:ok, %{"registered" => true}} =
               Client.register_mcp(base_url, "symphony-tracker", %{"type" => "remote", "url" => "http://127.0.0.1:4000/mcp"}, opts)

      assert_request(
        "POST /mcp HTTP/1.1",
        %{"name" => "symphony-tracker", "config" => %{"type" => "remote", "url" => "http://127.0.0.1:4000/mcp"}},
        opts
      )

      assert {:ok, true} = Client.abort(base_url, "ses_abc", opts)
      assert_request("POST /session/ses_abc/abort HTTP/1.1", %{}, opts)

      assert {:ok, true} = Client.reply_permission(base_url, "ses_abc", "perm_123", "once", opts)
      assert_request("POST /session/ses_abc/permissions/perm_123 HTTP/1.1", %{"response" => "once"}, opts)

      assert {:ok, %{"healthy" => true}} = Client.health(base_url, opts)
      assert_request("GET /global/health HTTP/1.1", nil, opts)

      assert :ok = Task.await(server)
    end

    test "returns a typed error when a successful message body lacks an assistant payload" do
      for response_body <- [
            ["not", "a", "message"],
            %{},
            %{"info" => "not a message"},
            %{"message" => %{"info" => %{}}}
          ] do
        {base_url, server} = start_server([json_response(response_body)])

        assert {:error, {:opencode_response_malformed, "/session/ses_abc/message", ^response_body}} =
                 Client.send_message(base_url, "ses_abc", %{"parts" => []})

        assert_request("POST /session/ses_abc/message HTTP/1.1", %{"parts" => []}, [])
        assert :ok = Task.await(server)
      end
    end

    test "accepts OpenCode assistant responses and supported legacy envelopes" do
      responses = [
        %{"info" => %{"id" => "msg_1", "sessionID" => "ses_abc", "role" => "assistant"}, "parts" => []},
        %{"message" => %{"info" => %{"role" => "assistant"}}},
        %{"role" => "assistant"},
        %{"info" => %{"error" => %{"name" => "ContextOverflowError"}}},
        %{message: %{info: %{role: :assistant, error: %{name: "ContextOverflowError"}}}}
      ]

      for response_body <- responses do
        request_fun = fn :post, _base_url, "/session/ses_abc/message", %{}, %{"parts" => []}, _opts -> {:ok, response_body} end

        assert {:ok, ^response_body} = Client.send_message("http://127.0.0.1:0", "ses_abc", %{"parts" => []}, request_fun: request_fun)
      end
    end

    test "returns a typed error when a boolean lifecycle endpoint returns an object" do
      request_fun = fn :post, _base_url, "/session/ses_abc/abort", %{}, %{}, _opts -> {:ok, %{}} end

      assert {:error, {:opencode_response_malformed, "/session/ses_abc/abort", %{}}} =
               Client.abort("http://127.0.0.1:0", "ses_abc", request_fun: request_fun)
    end

    test "maps non-successful HTTP responses and transport failures" do
      {base_url, server} = start_server([json_response(%{"error" => "unavailable"}, 503)])

      assert {:error, {:opencode_http_error, 503, %{"error" => "unavailable"}}} = Client.health(base_url)
      assert_request("GET /global/health HTTP/1.1", nil, [])
      assert :ok = Task.await(server)

      {unreachable_url, listener} = unavailable_url()
      assert {:error, {:opencode_transport_error, _reason}} = Client.health(unreachable_url, receive_timeout: 50)
      :ok = :gen_tcp.close(listener)
    end

    test "uses default options without sending credentials" do
      {base_url, server} =
        start_server([
          json_response(%{"id" => "ses_default"}),
          json_response(true),
          json_response(true),
          json_response(%{"registered" => true}),
          json_response(%{"healthy" => true})
        ])

      assert {:ok, %{"id" => "ses_default"}} = Client.create_session(base_url, "/workspaces/GH-2")
      assert_request("POST /session?directory=%2Fworkspaces%2FGH-2 HTTP/1.1", %{"title" => "Symphony ticket"}, [])

      assert {:ok, true} = Client.abort(base_url, "ses_default")
      assert_request("POST /session/ses_default/abort HTTP/1.1", %{}, [])

      assert {:ok, true} = Client.reply_permission(base_url, "ses_default", "perm_default", "always")
      assert_request("POST /session/ses_default/permissions/perm_default HTTP/1.1", %{"response" => "always"}, [])

      assert {:ok, %{"registered" => true}} = Client.register_mcp(base_url, "default-server", %{})
      assert_request("POST /mcp HTTP/1.1", %{"name" => "default-server", "config" => %{}}, [])

      assert {:ok, %{"healthy" => true}} = Client.health(base_url, password: "")
      assert_request("GET /global/health HTTP/1.1", nil, [])

      assert :ok = Task.await(server)
    end
  end

  defp assert_request(request_line, expected_body, opts) do
    assert_receive {:opencode_request, request}, 1_000
    assert String.starts_with?(request, request_line)

    if opts[:password] do
      assert request =~ "authorization: Basic " <> Base.encode64("#{opts[:username] || "opencode"}:#{opts[:password]}")
    else
      refute request =~ "authorization: Basic"
    end

    case expected_body do
      nil -> refute request =~ "content-type: application/json"
      body -> assert request =~ Jason.encode!(body)
    end
  end

  defp start_server(responses) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    parent = self()

    task =
      Task.async(fn ->
        Enum.each(responses, fn response ->
          {:ok, socket} = :gen_tcp.accept(listener)
          request = read_request(socket)
          send(parent, {:opencode_request, request})
          :ok = :gen_tcp.send(socket, response)
          :ok = :gen_tcp.close(socket)
        end)

        :ok = :gen_tcp.close(listener)
      end)

    {"http://127.0.0.1:#{port}", task}
  end

  defp unavailable_url do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    {"http://127.0.0.1:#{port}", listener}
  end

  defp json_response(body, status \\ 200) do
    encoded_body = Jason.encode!(body)

    "HTTP/1.1 #{status} #{reason_phrase(status)}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(encoded_body)}\r\nconnection: close\r\n\r\n#{encoded_body}"
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(503), do: "Service Unavailable"

  defp read_request(socket, buffer \\ "") do
    case :binary.match(buffer, "\r\n\r\n") do
      {headers_size, 4} ->
        <<headers::binary-size(headers_size), "\r\n\r\n", body::binary>> = buffer
        content_length = content_length(headers)

        if byte_size(body) >= content_length do
          buffer
        else
          {:ok, chunk} = :gen_tcp.recv(socket, 0)
          read_request(socket, buffer <> chunk)
        end

      :nomatch ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0)
        read_request(socket, buffer <> chunk)
    end
  end

  defp content_length(headers) do
    case Regex.run(~r/content-length: (\d+)/i, headers) do
      [_, value] -> String.to_integer(value)
      nil -> 0
    end
  end
end
