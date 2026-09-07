defmodule SymphonyElixir.OpencodeAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.Opencode.Adapter

  @settings %{
    command: "opencode serve",
    base_url: nil,
    host: "127.0.0.1",
    port: 4096,
    model: "meta/muse-spark-1.3",
    agent: "build",
    variant: "high",
    mcp_url: nil,
    turn_timeout_ms: 3_600_000,
    read_timeout_ms: 30_000,
    startup_timeout_ms: 30_000
  }

  # Stands in for the server: records every call and replays scripted responses,
  # so the adapter is exercised without a live opencode instance.
  defp fake_server(responses) do
    parent = self()

    fn method, base_url, path, params, body, _opts ->
      send(parent, {:request, method, base_url, path, params, body})

      case Map.fetch(responses, path) do
        {:ok, response} -> response
        :error -> {:error, {:unexpected_path, path}}
      end
    end
  end

  defp start_session(request_fun, settings \\ @settings) do
    Adapter.start_session("/workspaces/GH-1", settings: settings, request_fun: request_fun)
  end

  describe "session lifecycle" do
    test "binds the session to the ticket workspace directory" do
      request_fun = fake_server(%{"/session" => {:ok, %{"id" => "ses_abc"}}})

      assert {:ok, session} = start_session(request_fun)
      assert session.session_id == "ses_abc"
      assert session.base_url == "http://127.0.0.1:4096"

      assert_received {:request, :post, _base, "/session", %{"directory" => "/workspaces/GH-1"}, _body}
    end

    test "prefers an operator-supplied base_url over host and port" do
      settings = %{@settings | base_url: "http://elsewhere:9999/"}
      request_fun = fake_server(%{"/session" => {:ok, %{"id" => "ses_abc"}}})

      assert {:ok, session} = start_session(request_fun, settings)
      assert session.base_url == "http://elsewhere:9999"
    end

    test "reports a malformed session response instead of proceeding" do
      request_fun = fake_server(%{"/session" => {:ok, %{"unexpected" => true}}})

      assert {:error, {:opencode_session_malformed, _body}} = start_session(request_fun)
    end
  end

  describe "tracker tools" do
    test "registers Symphony's MCP server against the new session" do
      settings = %{@settings | mcp_url: "http://127.0.0.1:4000/mcp"}

      request_fun =
        fake_server(%{"/session" => {:ok, %{"id" => "ses_abc"}}, "/mcp" => {:ok, %{"ok" => true}}})

      assert {:ok, _session} = start_session(request_fun, settings)

      assert_received {:request, :post, _base, "/session", _params, _body}
      assert_received {:request, :post, _base, "/mcp", _mcp_params, mcp_body}
      assert mcp_body["name"] == "symphony-tracker"
      assert mcp_body["config"]["type"] == "remote"
      assert mcp_body["config"]["url"] == "http://127.0.0.1:4000/mcp"
    end

    test "starts without tracker tools rather than failing when no endpoint is configured" do
      request_fun = fake_server(%{"/session" => {:ok, %{"id" => "ses_abc"}}})

      assert {:ok, _session} = start_session(request_fun)
      assert_received {:request, :post, _base, "/session", _params, _body}
      refute_received {:request, :post, _base, "/mcp", _p, _b}
    end

    test "does not abort a session when tool registration fails" do
      settings = %{@settings | mcp_url: "http://127.0.0.1:4000/mcp"}

      request_fun =
        fake_server(%{
          "/session" => {:ok, %{"id" => "ses_abc"}},
          "/mcp" => {:error, {:opencode_http_error, 500, ""}}
        })

      assert {:ok, session} = start_session(request_fun, settings)
      assert session.session_id == "ses_abc"
    end
  end

  describe "running a turn" do
    test "sends the policy's model, agent and variant with the prompt" do
      request_fun =
        fake_server(%{
          "/session" => {:ok, %{"id" => "ses_abc"}},
          "/session/ses_abc/message" => {:ok, %{"info" => %{"role" => "assistant"}}}
        })

      {:ok, session} = start_session(request_fun)
      assert {:ok, _result} = Adapter.run_turn(session, "Deliver GH-1.", %{}, request_fun: request_fun)

      assert_received {:request, :post, _base, "/session", _params, _create_body}

      assert_received {:request, :post, _base, "/session/ses_abc/message", _params, body}
      assert body["model"] == %{"providerID" => "meta", "modelID" => "muse-spark-1.3"}
      assert body["agent"] == "build"
      assert body["variant"] == "high"
      assert body["parts"] == [%{"type" => "text", "text" => "Deliver GH-1."}]
    end

    test "omits a variant the policy does not set" do
      request_fun =
        fake_server(%{
          "/session" => {:ok, %{"id" => "ses_abc"}},
          "/session/ses_abc/message" => {:ok, %{"info" => %{}}}
        })

      {:ok, session} = start_session(request_fun, %{@settings | variant: nil})
      assert {:ok, _result} = Adapter.run_turn(session, "prompt", %{}, request_fun: request_fun)

      assert_received {:request, :post, _base, "/session", _params, _create}
      assert_received {:request, :post, _base, "/session/ses_abc/message", _params, body}
      refute Map.has_key?(body, "variant")
    end

    test "surfaces an assistant-message error as a failed turn" do
      request_fun =
        fake_server(%{
          "/session" => {:ok, %{"id" => "ses_abc"}},
          "/session/ses_abc/message" => {:ok, %{"info" => %{"error" => %{"name" => "ContextOverflowError"}}}}
        })

      {:ok, session} = start_session(request_fun)

      assert {:error, {:turn_failed, %{"name" => "ContextOverflowError"}}} =
               Adapter.run_turn(session, "prompt", %{}, request_fun: request_fun)
    end
  end

  describe "dashboard visibility" do
    test "reports session start and turn completion so a live worker is distinguishable from a hung one" do
      request_fun =
        fake_server(%{
          "/session" => {:ok, %{"id" => "ses_abc"}},
          "/session/ses_abc/message" => {:ok, %{"info" => %{"tokens" => %{"input" => 40, "output" => 5}, "cost" => 0.01}}}
        })

      {:ok, session} = start_session(request_fun)
      parent = self()
      on_message = fn update -> send(parent, {:update, update}) end

      assert {:ok, _} =
               Adapter.run_turn(session, "prompt", %{}, request_fun: request_fun, on_message: on_message)

      assert_received {:update, %{event: :session_started, session_id: "ses_abc", timestamp: %DateTime{}}}
      assert_received {:update, %{event: :turn_completed, session_id: "ses_abc"} = completed}

      # The orchestrator reads usage straight off the update it was handed.
      assert {usage, nil} = Adapter.extract_usage(completed)
      assert usage["input_tokens"] == 40
      assert usage["output_tokens"] == 5
      assert usage["cost_usd"] == 0.01
    end

    test "runs without a handler, so a caller that wants no updates is not a crash" do
      request_fun =
        fake_server(%{
          "/session" => {:ok, %{"id" => "ses_abc"}},
          "/session/ses_abc/message" => {:ok, %{"info" => %{}}}
        })

      {:ok, session} = start_session(request_fun)
      assert {:ok, _} = Adapter.run_turn(session, "prompt", %{}, request_fun: request_fun)
    end
  end

  describe "turn budget" do
    test "an overrun turn is terminal, not a transient transport blip" do
      request_fun =
        fake_server(%{
          "/session" => {:ok, %{"id" => "ses_abc"}},
          "/session/ses_abc/message" => {:error, {:opencode_transport_error, %Req.TransportError{reason: :timeout}}}
        })

      {:ok, session} = start_session(request_fun)

      assert {:error, {:turn_failed, %{"name" => "TurnBudgetExceeded"} = detail}} =
               Adapter.run_turn(session, "prompt", %{}, request_fun: request_fun)

      assert detail["data"]["turn_timeout_ms"] == @settings.turn_timeout_ms

      # Retrying spends the entire budget again on a turn that overruns again.
      assert Adapter.classify_failure({:turn_failed, detail}) == :terminal
    end

    test "a transport failure that is not the turn budget stays transient" do
      closed = %Req.TransportError{reason: :closed}
      failure = {:response_error, {:opencode_transport_error, closed}}

      assert Adapter.classify_failure(failure) == :transient
    end
  end

  describe "failure classification" do
    test "retries a server-side outage" do
      for name <- ["ServiceUnavailableError", "SessionBusyError"] do
        assert Adapter.classify_failure({:turn_failed, %{"name" => name}}) == :transient
      end

      assert Adapter.classify_failure({:response_error, {:opencode_transport_error, :timeout}}) ==
               :transient

      assert Adapter.classify_failure({:response_error, {:opencode_http_error, 503, ""}}) ==
               :transient
    end

    test "does not retry credentials, content or context failures" do
      for name <- ["ProviderAuthError", "ContentFilterError", "ContextOverflowError", "MessageAbortedError"] do
        assert Adapter.classify_failure({:turn_failed, %{"name" => name}}) == :terminal
      end

      assert Adapter.classify_failure({:response_error, {:opencode_http_error, 404, ""}}) ==
               :terminal
    end

    test "reads the upstream status inside an APIError rather than retrying blindly" do
      rate_limited = %{"name" => "APIError", "data" => %{"status" => 429}}
      bad_request = %{"name" => "APIError", "data" => %{"status" => 400}}

      assert Adapter.classify_failure({:turn_failed, rate_limited}) == :transient
      assert Adapter.classify_failure({:turn_failed, bad_request}) == :terminal
    end
  end

  describe "usage extraction" do
    test "reads the typed token block and cost from an assistant message" do
      message = %{
        "info" => %{
          "tokens" => %{
            "input" => 100,
            "output" => 20,
            "reasoning" => 5,
            "cache" => %{"read" => 900, "write" => 0}
          },
          "cost" => 0.0042
        }
      }

      assert {usage, nil} = Adapter.extract_usage(message)
      assert usage["input_tokens"] == 100
      assert usage["output_tokens"] == 20
      assert usage["reasoning_tokens"] == 5
      assert usage["cache_read_tokens"] == 900
      assert usage["total_tokens"] == 120
      assert usage["cost_usd"] == 0.0042
    end

    test "returns empty usage for an update carrying none" do
      assert {%{}, nil} = Adapter.extract_usage(%{"info" => %{}})
      assert {%{}, nil} = Adapter.extract_usage(:not_a_map)
    end
  end

  describe "capabilities and configuration" do
    test "declares that it does not enforce a filesystem sandbox" do
      capabilities = Adapter.capabilities()

      refute capabilities.sandbox_enforcement
      refute capabilities.rate_limit_reporting
      assert capabilities.structured_usage
    end

    test "requires a provider-qualified model" do
      assert :ok = Adapter.validate_config(%{opencode: @settings})

      assert {:error, {:invalid_workflow_config, message}} =
               Adapter.validate_config(%{opencode: %{@settings | model: "muse-spark-1.3"}})

      assert message =~ "provider/model"

      assert {:error, {:invalid_workflow_config, required}} =
               Adapter.validate_config(%{opencode: %{@settings | model: nil}})

      assert required =~ "required"
    end

    test "is selectable as an agent runtime kind" do
      assert {:ok, Adapter} = AgentRuntime.adapter_for_kind("opencode")
      assert "opencode" in AgentRuntime.supported_kinds()
    end
  end
end
