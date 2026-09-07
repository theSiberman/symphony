defmodule SymphonyElixir.AgentRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.Codex.Adapter, as: CodexAdapter

  describe "adapter selection" do
    test "resolves the declared kind and names the supported set when it is unknown" do
      assert {:ok, CodexAdapter} = AgentRuntime.adapter_for_kind("codex")

      assert {:error, {:unsupported_agent_runtime_kind, "nonexistent"}} =
               AgentRuntime.adapter_for_kind("nonexistent")

      assert "codex" in AgentRuntime.supported_kinds()
    end

    test "defaults to codex so an existing workflow file keeps its meaning" do
      write_workflow_file!(Workflow.workflow_file_path())

      assert Config.settings!().agent.kind == "codex"
      assert AgentRuntime.adapter() == CodexAdapter
    end

    test "rejects a workflow declaring a runtime with no adapter" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "nonexistent")

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "not a supported agent runtime"
    end
  end

  describe "capability declaration" do
    test "codex declares what the orchestrator may assume" do
      capabilities = CodexAdapter.capabilities()

      assert capabilities.structured_usage
      assert capabilities.rate_limit_reporting
      assert capabilities.sandbox_enforcement
      assert capabilities.session_resume
    end
  end

  describe "progress reporting capability" do
    test "codex streams, so silence between turns is evidence of a stall" do
      assert CodexAdapter.capabilities().streams_progress
    end

    test "opencode reports only at turn boundaries, so silence is not a stall" do
      refute SymphonyElixir.Opencode.Adapter.capabilities().streams_progress
    end

    test "an adapter that omits the capability is assumed to stream" do
      # Conservative default: keep watching a runtime that has not said otherwise.
      assert AgentRuntime.progress_silence_implies_stall?() in [true, false]
    end
  end

  describe "failure classification" do
    test "treats documented provider overload codes as transient" do
      for code <- ["rateLimitExceeded", "serverOverloaded", "internalServerError"] do
        assert CodexAdapter.classify_failure({:turn_failed, %{"codexErrorInfo" => code}}) ==
                 :transient
      end
    end

    test "treats retryable HTTP status codes as transient through nested envelopes" do
      for status <- [429, 500, 503, 599, nil] do
        detail = %{
          "error" => %{
            "codexErrorInfo" => %{"httpConnectionFailed" => %{"httpStatusCode" => status}}
          }
        }

        assert CodexAdapter.classify_failure({:response_error, detail}) == :transient
      end
    end

    test "treats client errors and unrecognised shapes as terminal" do
      client_error = %{
        "codexErrorInfo" => %{"httpConnectionFailed" => %{"httpStatusCode" => 404}}
      }

      assert CodexAdapter.classify_failure({:turn_failed, client_error}) == :terminal
      assert CodexAdapter.classify_failure({:turn_failed, %{"somethingElse" => true}}) == :terminal
      assert CodexAdapter.classify_failure(:some_other_reason) == :terminal
    end
  end

  describe "usage extraction" do
    test "reads absolute token usage from the Codex-internal payload path" do
      update = %{
        "params" => %{
          "msg" => %{"payload" => %{"info" => %{"total_token_usage" => %{"input_tokens" => 12, "output_tokens" => 3}}}}
        }
      }

      assert {%{"input_tokens" => 12, "output_tokens" => 3}, _rate_limits} =
               CodexAdapter.extract_usage(update)
    end

    test "reads usage carried directly on a completed turn" do
      update = %{"method" => "turn/completed", "usage" => %{"total_tokens" => 40}}

      assert {%{"total_tokens" => 40}, _rate_limits} = CodexAdapter.extract_usage(update)
    end

    test "finds a rate-limit bucket nested anywhere in the payload" do
      update = %{
        "payload" => %{"anything" => %{"limit_id" => "primary-limit", "primary" => %{"used" => 4}}}
      }

      assert {_usage, %{"limit_id" => "primary-limit"}} = CodexAdapter.extract_usage(update)
    end

    test "returns empty usage rather than failing on an unrecognised update" do
      assert {%{}, nil} = CodexAdapter.extract_usage(%{"unrelated" => true})
      assert {%{}, nil} = CodexAdapter.extract_usage(:not_a_map)
    end
  end
end
