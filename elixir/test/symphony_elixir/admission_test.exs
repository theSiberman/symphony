defmodule SymphonyElixir.AdmissionTest do
  use SymphonyElixir.TestSupport

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    %{root: root}
  end

  test "pending admission remains responsive and shortage recovers on polling", %{root: root} do
    marker = Path.join(root, "capacity")
    command = "sleep 0.2; test -f '#{marker}' || { echo disk-shortage; exit 75; }"
    configure(command)
    pid = start_supervised!({Orchestrator, name: AdmissionRecovery})
    send(pid, :run_poll_cycle)
    assert %{admission: %{status: "waiting"}} = GenServer.call(pid, :snapshot, 100)
    eventually(fn -> :sys.get_state(pid).admission == {:waiting, "disk-shortage"} end)
    assert {:ok, []} = Tracker.fetch_issues_by_states(["Todo"])
    File.write!(marker, "available")
    send(pid, :run_poll_cycle)
    eventually(fn -> :sys.get_state(pid).admission == :idle end)
    assert %{running: [], retrying: []} = GenServer.call(pid, :snapshot, 100)
  end

  test "a successful old probe cannot authorize after reload", %{root: root} do
    started = Path.join(root, "started")
    configure("touch '#{started}'; sleep 0.2")
    pid = start_supervised!({Orchestrator, name: AdmissionReload})
    eventually(fn -> File.exists?(started) end)
    configure("echo unavailable; exit 75")
    eventually(fn -> :sys.get_state(pid).admission_task == nil end)
    refute :sys.get_state(pid).admission == :idle
    send(pid, :run_poll_cycle)
    eventually(fn -> :sys.get_state(pid).admission == {:waiting, "unavailable"} end)
  end

  test "restart does not carry previous capacity approval", %{root: root} do
    marker = Path.join(root, "capacity")
    File.write!(marker, "available")
    configure("test -f '#{marker}' || { echo occupied; exit 75; }")
    pid = start_supervised!({Orchestrator, name: AdmissionRestart})
    eventually(fn -> :sys.get_state(pid).admission == :idle end)
    stop_supervised!(Orchestrator)
    File.rm!(marker)
    restarted = start_supervised!({Orchestrator, name: AdmissionRestart})
    eventually(fn -> :sys.get_state(restarted).admission == {:waiting, "occupied"} end)
    assert %{running: []} = GenServer.call(restarted, :snapshot, 100)
  end

  test "delayed retries do not consume the sole execution slot" do
    state = %Orchestrator.State{max_concurrent_agents: 1, claimed: MapSet.new(["retry"]), retry_attempts: %{"retry" => %{attempt: 1, due_at_ms: System.monotonic_time(:millisecond) + 10_000}}}
    assert Orchestrator.available_slots_for_test(state) == 1
  end

  test "ready retry competes with higher-priority work in the same selection", %{root: root} do
    started = Path.join(root, "worker-starts")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      max_concurrent_agents: 1,
      admission_command: "sleep 0.2",
      workspace_root: Path.join(root, "workspaces"),
      hook_after_create: "pwd >> '#{started}'; exit 1",
      poll_interval_ms: 60_000
    )

    low = %Issue{id: "low", identifier: "LOW", title: "retry", dispatchable: true, state: "Todo", priority: 4}
    high = %Issue{id: "high", identifier: "HIGH", title: "new", dispatchable: true, state: "Todo", priority: 1}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [low, high])
    pid = start_supervised!({Orchestrator, name: AdmissionPriority})

    :sys.replace_state(pid, fn state ->
      %{state | retry_attempts: %{low.id => %{attempt: 2, due_at_ms: System.monotonic_time(:millisecond) - 1}}}
    end)

    eventually(fn -> File.exists?(started) end)
    assert File.read!(started) |> String.split("\n", trim: true) |> hd() |> String.ends_with?("HIGH")
  end

  test "exhausted abnormal failures preserve an exception across restart" do
    configure("exit 75")
    issue = %Issue{id: "exhausted", identifier: "FAIL", title: "repeated crash", dispatchable: true, state: "Todo"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    pid = start_supervised!({Orchestrator, name: AdmissionFailures})

    child =
      spawn(fn ->
        receive do
          :fail -> exit(:boom)
        end
      end)

    :sys.replace_state(pid, fn state ->
      ref = Process.monitor(child)

      entry = %{
        pid: child,
        ref: ref,
        identifier: issue.identifier,
        issue: issue,
        retry_attempt: 3,
        started_at: DateTime.utc_now()
      }

      %{state | running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
    end)

    send(child, :fail)
    eventually(fn -> :sys.get_state(pid).running == %{} end)
    assert :sys.get_state(pid).retry_attempts == %{}
    assert {:ok, [%Issue{state: "needs-info"}]} = Tracker.fetch_issues_by_ids([issue.id])
    stop_supervised!(Orchestrator)
    restarted = start_supervised!({Orchestrator, name: AdmissionFailures})
    assert %{running: []} = GenServer.call(restarted, :snapshot)
    assert {:ok, []} = Tracker.fetch_issues_by_states(["Todo"])
  end

  defp configure(command) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      admission_command: command,
      max_concurrent_agents: 1,
      poll_interval_ms: 60_000
    )
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    unless predicate.() do
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
