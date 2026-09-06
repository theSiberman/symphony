defmodule SymphonyElixir.FailureRecoveryTest do
  use SymphonyElixir.TestSupport

  defmodule OfflineGitHub do
    def fetch_issues_by_states(states) do
      {:ok, Agent.get(__MODULE__, fn state -> Enum.filter(state.issues, &(&1.state in states)) end)}
    end

    def fetch_issues_by_ids(ids) do
      Agent.get(__MODULE__, fn state ->
        if state.lookup_error, do: {:error, :temporary_unavailable}, else: {:ok, Enum.filter(state.issues, &(&1.id in ids))}
      end)
    end

    def request(method, path, _params, _body, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        state = %{state | requests: state.requests + 1}

        if state.pause_error do
          {{:ok, %{status: 503, body: %{}}}, state}
        else
          issues = updated_issues(state.issues, method, path)
          {{:ok, %{status: 200, body: %{}}}, %{state | issues: issues}}
        end
      end)
    end

    defp updated_issues(issues, "DELETE", path) do
      if String.ends_with?(path, "/ready-for-agent"),
        do: Enum.map(issues, &%{&1 | state: "needs-info", labels: ["needs-info"]}),
        else: issues
    end

    defp updated_issues(issues, _method, _path), do: issues
  end

  setup do
    root = Path.dirname(Workflow.workflow_file_path())

    issue = %Issue{
      id: "17",
      identifier: "GH-17",
      title: "eligible",
      state: "ready-for-agent",
      labels: ["ready-for-agent"],
      dispatchable: true
    }

    initial = %{issues: [issue], lookup_error: false, pause_error: false, requests: 0}
    provider = start_supervised!({Agent, fn -> initial end})
    Process.register(provider, OfflineGitHub)
    original = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, OfflineGitHub)

    on_exit(fn ->
      if original,
        do: Application.put_env(:symphony_elixir, :github_client_module, original),
        else: Application.delete_env(:symphony_elixir, :github_client_module)
    end)

    configure(root, "exit 75")
    %{root: root, issue: issue}
  end

  test "a real continuation retry timer backs off tracker errors without spending abnormal attempts", %{root: root, issue: issue} do
    update(%{lookup_error: true})
    pid = start_supervised!({Orchestrator, name: RetryLookupRecovery})
    crash(pid, issue, 0, :normal)
    eventually(fn -> match?(%{attempt: 0, error: "retry poll failed:" <> _}, :sys.get_state(pid).retry_attempts[issue.id]) end)
    retry = :sys.get_state(pid).retry_attempts[issue.id]
    assert retry.due_at_ms > System.monotonic_time(:millisecond) + 5_000
    assert Agent.get(OfflineGitHub, & &1.issues) == [issue]
    update(%{lookup_error: false})
    # Let the actual retry timer expire into the same host admission boundary.
    eventually(fn -> :sys.get_state(pid).retry_attempts[issue.id][:due_at_ms] <= System.monotonic_time(:millisecond) end, 1_500)
    refute File.exists?(Path.join(root, "worker-started"))
    configure(root, "true")
    send(pid, :run_poll_cycle)
    eventually(fn -> File.exists?(Path.join(root, "worker-started")) end)
  end

  test "transient provider failure retains the abnormal count and queue membership", %{issue: issue} do
    pid = start_supervised!({Orchestrator, name: ProviderRecovery})
    crash(pid, issue, 3, {:agent_failed, {:turn_failed, %{code: "temporarily_unavailable"}}})
    eventually(fn -> :sys.get_state(pid).running == %{} end)
    assert %{attempt: 3} = :sys.get_state(pid).retry_attempts[issue.id]
    assert Agent.get(OfflineGitHub, & &1.issues) == [issue]
    assert {:ok, []} = Workspace.pending_exceptions()
  end

  test "failed exception persistence survives restart before a workspace exists", %{root: root, issue: issue} do
    update(%{pause_error: true})
    pid = start_supervised!({Orchestrator, name: ExceptionRecovery})
    crash(pid, issue, 3, :boom)
    eventually(fn -> match?({:ok, [_]}, Workspace.pending_exceptions()) end)
    refute File.exists?(Path.join([root, "workspaces", "GH-17"]))
    stop_supervised!(Orchestrator)
    configure(root, "true")
    restarted = start_supervised!({Orchestrator, name: ExceptionRecovery})
    eventually(fn -> Agent.get(OfflineGitHub, & &1.requests) >= 2 end)
    assert %{running: []} = GenServer.call(restarted, :snapshot)
    refute File.exists?(Path.join(root, "worker-started"))
    update(%{pause_error: false})
    send(restarted, :run_poll_cycle)
    eventually(fn -> Workspace.pending_exceptions() == {:ok, []} end)
    assert [%Issue{state: "needs-info"}] = Agent.get(OfflineGitHub, & &1.issues)
    refute File.exists?(Path.join(root, "worker-started"))
  end

  defp crash(orchestrator, issue, attempt, reason) do
    child =
      spawn(fn ->
        receive do
          :finish -> exit(reason)
        end
      end)

    :sys.replace_state(orchestrator, fn state ->
      entry = %{
        pid: child,
        ref: Process.monitor(child),
        issue: issue,
        identifier: issue.identifier,
        retry_attempt: attempt,
        started_at: DateTime.utc_now()
      }

      %{state | running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
    end)

    send(child, :finish)
  end

  defp update(changes), do: Agent.update(OfflineGitHub, &Map.merge(&1, changes))

  defp configure(root, command) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github
      provider:
        repo: fixture/offline
        token: fixture-token
        state_source: labels
      required_labels: [ready-for-agent]
      active_states: [ready-for-agent]
      terminal_states: [closed]
    workspace:
      root: #{root}/workspaces
    polling:
      interval_ms: 60000
    agent:
      max_concurrent_agents: 1
      admission_command: #{inspect(command)}
    hooks:
      after_create: "touch '#{root}/worker-started'; exit 1"
    ---
    Test only.
    """)

    WorkflowStore.force_reload()
  end

  defp eventually(predicate, attempts \\ 300)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    unless predicate.() do
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
