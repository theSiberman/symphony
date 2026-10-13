defmodule SymphonyElixir.AsyncTrackerTest do
  use SymphonyElixir.TestSupport

  defmodule GitHub do
    def fetch_issues_by_states(states) do
      kind = if states == ["closed"], do: :terminal, else: :active
      issues = Agent.get(__MODULE__, &Enum.filter(&1.issues, fn issue -> issue.state in states end))
      respond(kind, {:ok, issues})
    end

    def fetch_issues_by_ids(ids) do
      issues = Agent.get(__MODULE__, &Enum.filter(&1.issues, fn issue -> issue.id in ids end))
      respond(:ids, {:ok, issues})
    end

    def request(method, path, _params, _body, opts) do
      kind = if method == "GET", do: :labels, else: :pause
      Agent.update(__MODULE__, &%{&1 | mutations: [{method, path, opts} | &1.mutations]})
      respond(kind, {:ok, %{status: 200, body: []}})
    end

    defp respond(kind, result) do
      gate =
        Agent.get_and_update(__MODULE__, fn state ->
          {state.gates[kind], %{state | calls: [kind | state.calls]}}
        end)

      if gate do
        send(gate, {:tracker_started, kind, self()})

        receive do
          {:tracker_reply, reply} -> reply
        end
      else
        result
      end
    end
  end

  setup do
    original = Application.get_env(:symphony_elixir, :github_client_module)
    provider = start_supervised!({Agent, fn -> %{issues: [], gates: %{}, calls: [], mutations: []} end})
    Process.register(provider, GitHub)
    Application.put_env(:symphony_elixir, :github_client_module, GitHub)
    root = Path.dirname(Workflow.workflow_file_path())
    configure(root)
    start_supervised!({Task.Supervisor, name: AsyncTasks})

    on_exit(fn ->
      if original,
        do: Application.put_env(:symphony_elixir, :github_client_module, original),
        else: Application.delete_env(:symphony_elixir, :github_client_module)
    end)

    %{root: root}
  end

  test "blocked queue reads leave snapshots, updates, and worker completion responsive" do
    pid = start_runtime()
    issue = issue()
    worker = add_worker(pid, issue)
    gate(:active)
    poll(pid)
    assert_receive {:tracker_started, :active, reader}
    timestamp = DateTime.utc_now()
    send(pid, {:codex_worker_update, issue.id, %{event: :notification, timestamp: timestamp, session_id: "live", usage: %{}}})
    assert %{running: [%{last_codex_timestamp: ^timestamp}], polling: %{checking?: true}} = GenServer.call(pid, :snapshot, 100)
    send(worker, {:finish, :boom})
    eventually(fn -> Map.has_key?(:sys.get_state(pid).retry_attempts, issue.id) end)
    assert %{running: [], retrying: [%{attempt: 2}]} = GenServer.call(pid, :snapshot, 100)
    ungate(:active)
    send(reader, {:tracker_reply, {:ok, []}})
    wait_idle(pid)
    assert :sys.get_state(pid).retry_attempts[issue.id].attempt == 2
  end

  test "fixture teardown retires blocked default tracker work and preserves the task supervisor" do
    task_supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)
    assert is_pid(task_supervisor)
    gate(:active)
    assert {:ok, scheduler} = Supervisor.restart_child(SymphonyElixir.AgentRuntimeSupervisor, Orchestrator)
    assert_receive {:tracker_started, :active, reader}, 1_000
    assert %{polling: %{checking?: true}} = GenServer.call(scheduler, :snapshot, 100)
    assert :ok = SymphonyElixir.TestSupport.stop_default_orchestrator()
    refute Process.alive?(scheduler)
    refute Process.alive?(reader)
    assert Process.whereis(SymphonyElixir.TaskSupervisor) == task_supervisor
    parent = self()
    assert {:ok, _} = Task.Supervisor.start_child(task_supervisor, fn -> send(parent, :task_supervisor_available) end)
    assert_receive :task_supervisor_available
    ungate(:active)
    assert {:ok, restarted} = Supervisor.restart_child(SymphonyElixir.AgentRuntimeSupervisor, Orchestrator)
    assert %{running: []} = GenServer.call(restarted, :snapshot, 100)
    assert Process.whereis(SymphonyElixir.TaskSupervisor) == task_supervisor
    assert :ok = SymphonyElixir.TestSupport.stop_default_orchestrator()
  end

  test "an old reconciliation result cannot terminate a replacement worker" do
    pid = start_runtime()
    issue = issue()
    old = add_worker(pid, issue)
    gate(:ids)
    poll(pid)
    assert_receive {:tracker_started, :ids, reader}
    replacement = add_worker(pid, issue)
    send(old, {:finish, :normal})
    assert %{running: [_]} = GenServer.call(pid, :snapshot, 100)
    ungate(:ids)
    send(reader, {:tracker_reply, {:ok, [%{issue | state: "closed"}]}})
    wait_idle(pid)
    assert Process.alive?(replacement)
    assert :sys.get_state(pid).running[issue.id].pid == replacement
    assert :sys.get_state(pid).retry_attempts == %{}
  end

  test "due retries retain their diagnostics and ignore a superseded retry lookup" do
    pid = start_runtime()
    issue = issue()
    token = make_ref()

    retry = %{
      attempt: 3,
      due_at_ms: System.monotonic_time(:millisecond) - 1,
      retry_token: token,
      timer_ref: nil,
      identifier: issue.identifier,
      error: "setup failed"
    }

    :sys.replace_state(pid, &%{&1 | retry_attempts: %{issue.id => retry}})
    gate(:ids)
    send(pid, {:retry_issue, issue.id, token})
    assert_receive {:tracker_started, :ids, reader}
    assert %{retrying: [%{attempt: 3, error: "setup failed"}]} = GenServer.call(pid, :snapshot, 100)

    newer = %{
      retry
      | retry_token: make_ref(),
        attempt: 4,
        error: "newer failure",
        due_at_ms: System.monotonic_time(:millisecond) + 60_000
    }

    :sys.replace_state(pid, &put_in(&1.retry_attempts[issue.id], newer))
    ungate(:ids)
    send(reader, {:tracker_reply, {:ok, []}})
    wait_idle(pid)
    assert :sys.get_state(pid).retry_attempts[issue.id] == newer
  end

  test "fresh dispatch validation stays responsive and a new retry cancels stale dispatch", %{root: root} do
    pid = start_runtime()
    issue = issue()
    update(%{issues: [issue]})
    gate(:ids)
    poll(pid)
    assert_receive {:tracker_started, :ids, reader}
    assert %{running: [], polling: %{checking?: true}} = GenServer.call(pid, :snapshot, 100)
    retry = %{attempt: 2, due_at_ms: System.monotonic_time(:millisecond) + 60_000, error: "new failure"}
    :sys.replace_state(pid, &put_in(&1.retry_attempts[issue.id], retry))
    ungate(:ids)
    send(reader, {:tracker_reply, {:ok, [issue]}})
    wait_idle(pid)
    assert :sys.get_state(pid).running == %{}
    assert :sys.get_state(pid).retry_attempts[issue.id] == retry
    refute File.exists?(Path.join(root, "worker-started"))
  end

  test "workflow reload discards in-flight dispatch and refreshes the new queue", %{root: root} do
    pid = start_runtime()
    issue = issue()
    update(%{issues: [issue]})
    gate(:ids)
    poll(pid)
    assert_receive {:tracker_started, :ids, reader}
    configure(root, "other/repository")
    update(%{issues: []})
    ungate(:ids)
    send(reader, {:tracker_reply, {:ok, [issue]}})
    wait_idle(pid)
    assert :sys.get_state(pid).running == %{}
    refute File.exists?(Path.join(root, "worker-started"))
    assert %{polling: %{checking?: false}} = GenServer.call(pid, :snapshot, 100)
  end

  test "a crashed tracker task clears checking and the next refresh recovers" do
    pid = start_runtime()
    gate(:active)
    poll(pid)
    assert_receive {:tracker_started, :active, reader}
    Process.exit(reader, :kill)
    wait_idle(pid)
    assert %{polling: %{checking?: false, next_poll_in_ms: remaining}} = GenServer.call(pid, :snapshot, 100)
    assert is_integer(remaining)
    ungate(:active)
    poll(pid)
    wait_idle(pid)
    assert %{polling: %{checking?: false}} = GenServer.call(pid, :snapshot, 100)
  end

  test "repeated poll requests coalesce while a terminal sweep blocks" do
    gate(:terminal)
    pid = start_supervised!({Orchestrator, name: AsyncOrchestrator, task_supervisor: AsyncTasks})
    assert_receive {:tracker_started, :terminal, reader}, 1_000
    for _ <- 1..20, do: poll(pid)
    assert %{polling: %{checking?: true}} = GenServer.call(pid, :snapshot, 100)
    assert Agent.get(GitHub, &Enum.count(&1.calls, fn kind -> kind == :terminal end)) == 1
    ungate(:terminal)
    send(reader, {:tracker_reply, {:ok, []}})
    wait_idle(pid)
    assert Agent.get(GitHub, &Enum.count(&1.calls, fn kind -> kind == :active end)) == 2
  end

  test "pending cleanup records cannot delete a checkout owned by a running worker", %{root: root} do
    pid = start_runtime()
    issue = issue()
    worker = add_worker(pid, issue)
    record = Path.join([root, "workspaces", ".symphony-cleanup", "GH-17.json"])
    File.mkdir_p!(Path.dirname(record))
    File.write!(record, "{}")
    update(%{calls: []})
    poll(pid)
    wait_idle(pid)
    assert Process.alive?(worker)
    assert File.exists?(record)
    refute :terminal in Agent.get(GitHub, & &1.calls)
  end

  test "running-label writes stay responsive and replay the latest ownership set", %{root: root} do
    configure(root, "fixture/repository", true)
    gate(:labels)
    pid = start_supervised!({Orchestrator, name: AsyncOrchestrator, task_supervisor: AsyncTasks})
    assert_receive {:tracker_started, :labels, writer}, 1_000
    assert %{running: []} = GenServer.call(pid, :snapshot, 100)
    issue = issue()
    add_worker(pid, issue)
    ungate(:labels)
    send(writer, {:tracker_reply, {:ok, %{status: 200, body: []}}})
    eventually(fn -> :sys.get_state(pid).label_task == nil end)
    mutations = Agent.get(GitHub, & &1.mutations)
    assert Enum.any?(mutations, fn {method, path, _} -> method == "POST" and path == "/repos/fixture/repository/issues/17/labels" end)
  end

  test "a delayed terminal discovery cannot remove work after workflow reload", %{root: root} do
    issue = %{issue() | state: "closed"}
    workspace = Path.join([root, "workspaces", issue.identifier])
    origin = Path.join(root, "origin.git")
    File.mkdir_p!(workspace)
    git(["init", "-q", workspace])
    File.write!(Path.join(workspace, "README.md"), "published work")
    git(["-C", workspace, "add", "README.md"])
    git(["-C", workspace, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "initial"])
    git(["init", "--bare", "-q", origin])
    git(["-C", workspace, "remote", "add", "origin", origin])
    git(["-C", workspace, "push", "-qu", "--set-upstream", "origin", "HEAD"])
    gate(:terminal)
    task = Task.async(fn -> Workspace.reconcile_terminal_workspaces() end)
    assert_receive {:tracker_started, :terminal, reader}, 1_000
    configure(root, "other/repository")
    ungate(:terminal)
    send(reader, {:tracker_reply, {:ok, [issue]}})
    assert :ok = Task.await(task)
    assert File.exists?(workspace)
  end

  test "a delayed pending cleanup lookup cannot remove work after workflow reload", %{root: root} do
    issue = %{issue() | state: "closed"}
    workspace = Path.join([root, "workspaces", issue.identifier])
    key = :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower)
    record = Path.join([root, "workspaces", ".symphony-cleanup", key <> ".json"])
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.dirname(record))
    File.write!(record, Jason.encode!(%{workspace: workspace}))
    gate(:terminal)
    task = Task.async(fn -> Workspace.reconcile_cleanup() end)
    assert_receive {:tracker_started, :terminal, reader}, 1_000
    configure(root, "other/repository")
    ungate(:terminal)
    send(reader, {:tracker_reply, {:ok, [issue]}})
    assert :ok = Task.await(task)
    assert File.exists?(workspace)
    assert File.exists?(record)
  end

  defp start_runtime do
    pid = start_supervised!({Orchestrator, name: AsyncOrchestrator, task_supervisor: AsyncTasks})
    poll(pid)
    GenServer.call(pid, :snapshot, 100)
    wait_idle(pid)
    pid
  end

  defp issue, do: %Issue{id: "17", identifier: "GH-17", title: "fixture", state: "ready", labels: ["ready"], dispatchable: true}

  defp git(args) do
    assert {_, 0} = System.cmd("git", args, stderr_to_stdout: true)
  end

  defp add_worker(pid, issue) do
    update(%{issues: [issue]})

    {:ok, worker} =
      Task.Supervisor.start_child(AsyncTasks, fn ->
        receive do
          {:finish, reason} -> exit(reason)
        end
      end)

    :sys.replace_state(pid, fn state ->
      entry = %{
        pid: worker,
        ref: Process.monitor(worker),
        identifier: issue.identifier,
        issue: issue,
        retry_attempt: 1,
        session_id: nil,
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        last_codex_timestamp: nil,
        last_codex_message: nil,
        last_codex_event: nil,
        started_at: DateTime.utc_now()
      }

      %{state | running: Map.put(state.running, issue.id, entry), claimed: MapSet.put(state.claimed, issue.id)}
    end)

    worker
  end

  defp configure(root, repo \\ "fixture/repository", labels \\ false) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github
      provider:
        repo: #{repo}
        token: fixture-token
        state_source: labels
        managed_running_label: #{if labels, do: "in-progress", else: "null"}
      required_labels: [ready]
      active_states: [ready]
      terminal_states: [closed]
    workspace:
      root: #{root}/workspaces
    polling:
      interval_ms: 3600000
    hooks:
      after_create: "touch '#{root}/worker-started'; exit 1"
    ---
    Fixture.
    """)

    WorkflowStore.force_reload()
  end

  defp gate(kind) do
    test_pid = self()
    Agent.update(GitHub, &put_in(&1.gates[kind], test_pid))
  end

  defp ungate(kind), do: Agent.update(GitHub, &%{&1 | gates: Map.delete(&1.gates, kind)})
  defp update(changes), do: Agent.update(GitHub, &Map.merge(&1, changes))
  defp poll(pid), do: send(pid, :run_poll_cycle)

  defp wait_idle(pid),
    do:
      eventually(fn ->
        state = :sys.get_state(pid)
        state.tracker_task == nil and not state.poll_check_in_progress
      end)

  defp eventually(predicate, attempts \\ 200)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    unless predicate.() do
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
