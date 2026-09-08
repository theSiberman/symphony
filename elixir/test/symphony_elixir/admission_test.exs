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
    started = Path.join(root, "worker-started")
    issue = %Issue{id: "capacity", identifier: "CAP", title: "eligible", state: "Todo", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    configure(command, hook_after_create: "touch '#{started}'; exit 1")
    pid = start_supervised!({Orchestrator, name: AdmissionRecovery})
    send(pid, :run_poll_cycle)
    assert %{admission: %{status: "waiting"}} = GenServer.call(pid, :snapshot, 100)
    eventually(fn -> :sys.get_state(pid).admission == {:waiting, "disk-shortage"} end)
    assert {:ok, [^issue]} = Tracker.fetch_issues_by_states(["Todo"])
    refute File.exists?(started)
    File.write!(marker, "available")
    send(pid, :run_poll_cycle)
    eventually(fn -> File.exists?(started) end)
    assert {:ok, [^issue]} = Tracker.fetch_issues_by_states(["Todo"])
  end

  test "capacity is probed while work is running, so later work can still start", %{root: root} do
    # The bug this pins: check_admission forced :unchecked whenever anything was
    # running, and admission_available? demands :available, so maybe_dispatch
    # short-circuited before choose_issues. With an admission_command set,
    # Symphony could only admit while `running` was empty -- a hard cap of one
    # concurrent agent no matter what max_concurrent_agents said, and silent,
    # because the config read correctly and the dashboard just showed one agent.
    #
    # The second candidate must arrive in a LATER poll than the first. That is
    # the production shape and the only one that discriminates: within a single
    # cycle choose_issues fills every slot before anything is running, so both
    # would dispatch even with the bug present.
    marker = Path.join(root, "dispatched")
    first = %Issue{id: "one", identifier: "ONE", title: "first", state: "Todo", dispatchable: true}
    second = %Issue{id: "two", identifier: "TWO", title: "second", state: "Todo", dispatchable: true}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [first])

    configure("exit 0",
      max_concurrent_agents: 2,
      hook_after_create: "touch '#{marker}'-$SYMPHONY_ISSUE_IDENTIFIER; sleep 2; exit 1"
    )

    pid = start_supervised!({Orchestrator, name: AdmissionConcurrent})
    send(pid, :run_poll_cycle)
    eventually(fn -> File.exists?("#{marker}-ONE") end)
    eventually(fn -> map_size(:sys.get_state(pid).running) == 1 end)

    # The second becomes available with the first still in flight.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [first, second])
    send(pid, :run_poll_cycle)

    eventually(fn -> File.exists?("#{marker}-TWO") end)
    assert map_size(:sys.get_state(pid).running) == 2
  end

  test "a shortage discovered while running stops further admission", %{root: root} do
    # The safety property the fix must not lose. Probing while busy is only
    # correct if a NO is still obeyed; otherwise this trades a silent
    # concurrency cap for a silent capacity breach.
    capacity = Path.join(root, "capacity-ok")
    File.write!(capacity, "yes")
    marker = Path.join(root, "dispatched")
    first = %Issue{id: "a", identifier: "A", title: "first", state: "Todo", dispatchable: true}
    second = %Issue{id: "b", identifier: "B", title: "second", state: "Todo", dispatchable: true}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [first])

    configure("test -f '#{capacity}' || { echo disk-shortage; exit 75; }",
      max_concurrent_agents: 2,
      hook_after_create: "touch '#{marker}'-$SYMPHONY_ISSUE_IDENTIFIER; sleep 2; exit 1"
    )

    pid = start_supervised!({Orchestrator, name: AdmissionShortage})
    send(pid, :run_poll_cycle)
    eventually(fn -> File.exists?("#{marker}-A") end)

    # The host fills up while work is in flight, and the approval goes stale.
    File.rm!(capacity)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [first, second])
    send(pid, :run_poll_cycle)

    eventually(fn -> match?({:waiting, _}, :sys.get_state(pid).admission) end)
    refute File.exists?("#{marker}-B")
  end

  test "an approval is consumed each cycle, so no dispatch rests on an old probe", %{root: root} do
    # This is what makes probing-while-busy safe, and it predates the fix:
    # maybe_dispatch consumes :available back to :idle at the end of every
    # cycle, so the next cycle must probe again before selecting work. Without
    # it, removing the running-count branch would have been worse than the bug
    # -- one early yes would authorise every later dispatch and the host could
    # fill while Symphony kept admitting against it.
    probes = Path.join(root, "probes")
    File.mkdir_p!(probes)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    configure("touch '#{probes}'/$$-$RANDOM")
    pid = start_supervised!({Orchestrator, name: AdmissionFreshness})

    send(pid, :run_poll_cycle)
    eventually(fn -> length(File.ls!(probes)) >= 1 end)
    eventually(fn -> :sys.get_state(pid).admission_task == nil end)
    first_count = length(File.ls!(probes))

    # The approval was spent by the cycle that used it.
    assert :sys.get_state(pid).admission in [:idle, :available]

    # So the following cycle probes again rather than reusing the old answer.
    send(pid, :run_poll_cycle)
    eventually(fn -> length(File.ls!(probes)) > first_count end)
  end

  test "a successful old probe cannot authorize after reload", %{root: root} do
    started = Path.join(root, "started")
    worker = Path.join(root, "worker-started")
    issue = %Issue{id: "reload", identifier: "RELOAD", title: "eligible", state: "Todo", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    configure("touch '#{started}'; sleep 0.2", hook_after_create: "touch '#{worker}'; exit 1")
    pid = start_supervised!({Orchestrator, name: AdmissionReload})
    eventually(fn -> File.exists?(started) end)
    configure("echo unavailable; exit 75", hook_after_create: "touch '#{worker}'; exit 1")
    eventually(fn -> :sys.get_state(pid).admission_task == nil end)
    refute :sys.get_state(pid).admission == :idle
    send(pid, :run_poll_cycle)
    eventually(fn -> :sys.get_state(pid).admission == {:waiting, "unavailable"} end)
    refute File.exists?(worker)
    assert {:ok, [^issue]} = Tracker.fetch_issues_by_states(["Todo"])
  end

  test "restart does not carry previous capacity approval", %{root: root} do
    marker = Path.join(root, "capacity")
    File.write!(marker, "available")
    configure("test -f '#{marker}' || { echo occupied; exit 75; }")
    pid = start_supervised!({Orchestrator, name: AdmissionRestart})
    eventually(fn -> :sys.get_state(pid).admission == :idle end)
    stop_supervised!(Orchestrator)
    File.rm!(marker)
    worker = Path.join(root, "worker-started")
    issue = %Issue{id: "restart", identifier: "RESTART", title: "eligible", state: "Todo", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    configure("test -f '#{marker}' || { echo occupied; exit 75; }", hook_after_create: "touch '#{worker}'; exit 1")
    restarted = start_supervised!({Orchestrator, name: AdmissionRestart})
    eventually(fn -> :sys.get_state(restarted).admission == {:waiting, "occupied"} end)
    assert %{running: []} = GenServer.call(restarted, :snapshot, 100)
    refute File.exists?(worker)
    assert {:ok, [^issue]} = Tracker.fetch_issues_by_states(["Todo"])
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

  defp configure(command, overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
          admission_command: command,
          workspace_root: Path.join(Path.dirname(Workflow.workflow_file_path()), "workspaces"),
          max_concurrent_agents: 1,
          poll_interval_ms: 60_000
        ],
        overrides
      )
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
