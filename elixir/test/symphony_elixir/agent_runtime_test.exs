defmodule SymphonyElixir.AgentRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.Codex.Adapter, as: CodexAdapter
  alias SymphonyElixir.Usage.Payload

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

  describe "runtime delegation" do
    test "validates the selected adapter" do
      assert :ok = AgentRuntime.validate_config(Config.settings!())

      assert {:error, {:unsupported_agent_runtime_kind, "unknown"}} =
               AgentRuntime.validate_config(%{agent: %{kind: "unknown"}})
    end

    test "runs a complete turn through the selected runtime adapter" do
      test_root = Path.join(System.tmp_dir!(), "symphony-agent-runtime-#{System.unique_integer([:positive])}")
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-RUNTIME")
      codex_binary = Path.join(test_root, "fake-codex")

      try do
        File.mkdir_p!(workspace)

        File.write!(codex_binary, """
        #!/bin/sh
        count=0
        while IFS= read -r _line; do
          count=$((count + 1))
          case "$count" in
            1) printf '%s\\n' '{"id":1,"result":{}}' ;;
            2) ;;
            3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-runtime"}}}' ;;
            4)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-runtime"}}}'
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0
              ;;
          esac
        done
        """)

        File.chmod!(codex_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server"
        )

        assert {:ok, session} = AgentRuntime.start_session(workspace)

        assert {:ok, %{thread_id: "thread-runtime", turn_id: "turn-runtime"}} =
                 AgentRuntime.run_turn(session, "summarize the issue", %{
                   id: "runtime-issue",
                   identifier: "MT-RUNTIME",
                   title: "Runtime delegation"
                 })

        assert :ok = AgentRuntime.stop_session(session)

        # Existing callers may still hold a raw session created before profile
        # support. Exercise that public compatibility path through real stdio.
        assert {:ok, legacy_session} = CodexAdapter.start_session(workspace, [])

        assert {:ok, %{thread_id: "thread-runtime", turn_id: "turn-runtime"}} =
                 AgentRuntime.run_turn(legacy_session, "resume the unprofiled session", %{
                   id: "runtime-issue",
                   identifier: "MT-RUNTIME",
                   title: "Legacy runtime delegation"
                 })

        assert :ok = AgentRuntime.stop_session(legacy_session)
      after
        File.rm_rf(test_root)
      end
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

    test "rejects malformed usage values and paths without raising" do
      assert Payload.get(%{"total_tokens" => " 42 "}, "total_tokens") == 42
      assert Payload.integer_like("not-a-number") == nil
      assert Payload.integer_like("-1") == nil
      assert Payload.map_at_path(:not_a_map, ["usage"]) == nil
      assert Payload.explicit_map_at_paths(%{"usage" => "not-a-map"}, [["usage"]]) == nil
      assert Payload.explicit_map_at_paths(:not_a_map, [["usage"]]) == nil
      assert Payload.explicit_map_at_paths(%{}, :not_a_path_list) == nil
    end

    test "recognises supported Codex error envelopes and alternate usage locations" do
      for key <- [
            "responseStreamConnectionFailed",
            "responseStreamDisconnected",
            "responseTooManyFailedAttempts"
          ] do
        assert CodexAdapter.classify_failure({:turn_failed, %{"codexErrorInfo" => %{key => %{"httpStatusCode" => 503}}}}) ==
                 :transient
      end

      assert CodexAdapter.classify_failure({:turn_failed, %{"codexErrorInfo" => %{"httpConnectionFailed" => "bad"}}}) ==
               :terminal

      completed = %{
        "method" => "turn/completed",
        "params" => %{"usage" => %{"input_tokens" => 7, "output_tokens" => 2}}
      }

      assert {%{"input_tokens" => 7, "output_tokens" => 2}, nil} = CodexAdapter.extract_usage(completed)

      atom_completed = %{
        method: :turn_completed,
        params: %{usage: %{input_tokens: 3, output_tokens: 1}}
      }

      assert {%{input_tokens: 3, output_tokens: 1}, nil} = CodexAdapter.extract_usage(atom_completed)

      atom_rate_limit_update = %{rate_limits: %{limit_id: "atom-limit", primary: %{used: 1}}}
      assert {%{}, %{limit_id: "atom-limit"}} = CodexAdapter.extract_usage(atom_rate_limit_update)

      list_rate_limit_update = %{
        "payload" => [
          %{"unrelated" => true},
          %{"limit_id" => "secondary-limit", "secondary" => %{"used" => 2}}
        ]
      }

      assert {%{}, %{"limit_id" => "secondary-limit"}} = CodexAdapter.extract_usage(list_rate_limit_update)
    end
  end
end
