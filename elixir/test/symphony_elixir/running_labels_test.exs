defmodule SymphonyElixir.RunningLabelsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.RunningLabels

  defmodule GitHub do
    def request(method, path, params, body, opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        state = %{state | calls: state.calls ++ [{method, path, params, opts}]}

        respond(state, method, path, params, body)
      end)
    end

    defp respond(state, method, path, params, body) do
      cond do
        state.fail ->
          {{:ok, %{status: 503, body: %{}}}, state}

        method == "GET" ->
          items = Enum.map(Enum.sort(state.labels), &%{"number" => &1}) ++ state.extra
          page = Enum.slice(items, (params["page"] - 1) * 100, 100)
          {{:ok, %{status: 200, body: page}}, state}

        true ->
          [number] = Regex.run(~r{/issues/(\d+)/labels}, path, capture: :all_but_first)
          number = String.to_integer(number)
          labels = if method == "DELETE", do: MapSet.delete(state.labels, number), else: MapSet.put(state.labels, number)
          if method == "POST", do: true = body == %{"labels" => ["in-progress"]}
          {{:ok, %{status: 200, body: []}}, %{state | labels: labels}}
      end
    end

    def fetch_issues_by_states(_states), do: {:error, :candidate_reads_unavailable}
    def fetch_issues_by_ids(_ids), do: {:ok, Agent.get(__MODULE__, & &1.issues)}
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, GitHub)
    provider = start_supervised!({Agent, fn -> %{labels: MapSet.new(), calls: [], extra: [], fail: false, issues: []} end}, id: :labels)
    # Register the supervised fake provider without changing production process ownership.
    Process.register(provider, GitHub)

    on_exit(fn ->
      if previous do
        Application.put_env(:symphony_elixir, :github_client_module, previous)
      else
        Application.delete_env(:symphony_elixir, :github_client_module)
      end
    end)

    :ok
  end

  defp settings do
    %{
      kind: "github",
      provider: %{"repo" => "octo/repo", "token" => "test-token", "state_source" => "labels", "managed_running_label" => "in-progress"},
      active_states: ["ready"],
      terminal_states: ["closed"],
      required_labels: ["ready"]
    }
  end

  defp update(changes), do: Agent.update(GitHub, &Map.merge(&1, changes))
  defp labels, do: Agent.get(GitHub, & &1.labels)
  defp calls, do: Agent.get(GitHub, & &1.calls)
  defp reconcile(ids), do: RunningLabels.reconcile(settings(), ids, &GitHub.request/5)

  test "enumerates every page before removing stale markers, preserves active workers and ignores PRs" do
    update(%{labels: MapSet.new(1..102), extra: [%{"number" => 999, "pull_request" => %{}}]})
    assert :ok = reconcile(["1", "103"])
    assert labels() == MapSet.new([1, 103])
    assert [{"GET", _, %{"state" => "all", "page" => 1}, _}, {"GET", _, %{"page" => 2}, _} | writes] = calls()
    assert Enum.all?(writes, fn {method, path, _, _} -> method != "GET" and not String.contains?(path, "/999/") end)
    assert :ok = reconcile(["1", "103"])
    assert labels() == MapSet.new([1, 103])
  end

  test "failed enumeration preserves labels and later reconciliation repairs them" do
    update(%{labels: MapSet.new([1, 2]), fail: true})
    assert {:error, _} = reconcile(["1"])
    assert labels() == MapSet.new([1, 2])
    assert [{"GET", _, _, _}] = calls()
    update(%{fail: false})
    assert :ok = reconcile(["1"])
    assert labels() == MapSet.new([1])
  end

  test "transport failures and malformed responses return retryable errors without exposing provider details" do
    for {response, expected} <- [
          {{:error, {:network, "sensitive provider detail"}}, :running_label_request_failed},
          {:unexpected, :invalid_running_label_response}
        ] do
      request = fn _, _, _, _, _ -> response end
      assert {:error, ^expected} = RunningLabels.reconcile(settings(), ["1"], request)
      assert labels() == MapSet.new()
    end
  end

  test "partial mutation failures are retried and malformed responses never trigger writes" do
    request = fn method, path, params, body, opts ->
      if method == "DELETE" and String.contains?(path, "/2/") do
        {:ok, %{status: 403, body: %{}}}
      else
        GitHub.request(method, path, params, body, opts)
      end
    end

    update(%{labels: MapSet.new([1, 2, 3])})
    assert {:error, {:running_label_http_status, 403}} = RunningLabels.reconcile(settings(), [], request)
    assert labels() == MapSet.new([2])
    assert :ok = reconcile([])
    assert labels() == MapSet.new()
    update(%{extra: [%{"unexpected" => true}]})
    assert {:error, :invalid_running_label_payload} = reconcile(["1"])
    assert labels() == MapSet.new()
  end

  test "missing repository returns a recoverable error without requests or a scheduler crash" do
    invalid = put_in(settings(), [:provider, "repo"], "$SYMPHONY_TEST_MISSING_REPO")
    previous = System.get_env("GITHUB_REPO")
    System.delete_env("GITHUB_REPO")
    on_exit(fn -> restore_env("GITHUB_REPO", previous) end)
    binding = Tracker.bind_running_labels(invalid)
    assert {:error, :missing_github_repo} = Tracker.reconcile_running_labels(binding, [])
    assert calls() == []

    write_github_workflow()
    start_runtime()
    :sys.replace_state(LabelOrchestrator, &%{&1 | running_labels: binding})
    poll()
    assert Process.alive?(Process.whereis(LabelOrchestrator))
    assert :sys.get_state(LabelOrchestrator).running == %{}
  end

  test "ownership is opt-in, excludes queue labels, and binds repository identity across reloads" do
    disabled = %{settings() | provider: %{}}
    assert nil == Tracker.bind_running_labels(disabled)
    assert :ok = Tracker.reconcile_running_labels(nil, ["1"])
    assert calls() == []

    for label <- ["READY", "closed", " ", 42] do
      invalid = put_in(settings(), [:provider, "managed_running_label"], label)
      assert {:error, :invalid_github_managed_running_label} = RunningLabels.validate_config(invalid)
    end

    binding = Tracker.bind_running_labels(settings())
    assert Tracker.running_labels_compatible?(binding, settings())
    refute Tracker.running_labels_compatible?(binding, put_in(settings(), [:provider, "repo"], "other/repo"))
    refute Tracker.running_labels_compatible?(binding, disabled)
    assert :ok = Tracker.reconcile_running_labels(binding, ["1"])
    assert Enum.all?(calls(), fn {_, path, _, _} -> String.starts_with?(path, "/repos/octo/repo/") end)
  end

  test "startup, worker DOWN, paused-worker termination and failed candidate polls reconcile real runtime state" do
    write_github_workflow()
    update(%{labels: MapSet.new([283, 284])})
    start_runtime()
    poll()
    assert labels() == MapSet.new()

    worker = add_worker("321")
    poll()
    assert labels() == MapSet.new([321])
    Process.exit(worker, :kill)
    eventually(fn -> :sys.get_state(LabelOrchestrator).running == %{} end)
    assert labels() == MapSet.new()
    assert Map.has_key?(:sys.get_state(LabelOrchestrator).retry_attempts, "321")

    paused = add_worker("322")
    update(%{issues: [%Issue{id: "322", identifier: "GH-322", state: "needs-info"}]})
    poll()
    refute Process.alive?(paused)
    assert labels() == MapSet.new()
  end

  test "scheduler crash stops its workers before startup removes abandoned markers" do
    write_github_workflow()
    start_runtime()
    poll()
    worker = add_worker("321")
    poll()
    assert labels() == MapSet.new([321])
    original = Process.whereis(LabelOrchestrator)
    Process.exit(original, :kill)
    eventually(fn -> is_pid(Process.whereis(LabelOrchestrator)) and Process.whereis(LabelOrchestrator) != original end)
    poll()
    refute Process.alive?(worker)
    assert labels() == MapSet.new()
  end

  test "ownership reload keeps mutations on original repository and blocks new admissions" do
    write_github_workflow()
    start_runtime()
    poll()
    worker = add_worker("321")
    write_github_workflow("other/repo")
    update(%{calls: []})
    poll()
    assert Process.alive?(worker)
    assert labels() == MapSet.new([321])
    assert Enum.all?(calls(), fn {_, path, _, _} -> String.starts_with?(path, "/repos/octo/repo/") end)
    assert :sys.get_state(LabelOrchestrator).running |> Map.keys() == ["321"]
  end

  defp start_runtime do
    opts = [name: LabelRuntime, task_supervisor_name: LabelTasks, orchestrator_name: LabelOrchestrator]
    start_supervised!({SymphonyElixir.AgentRuntimeSupervisor, opts})
  end

  defp poll do
    send(LabelOrchestrator, :run_poll_cycle)
    :sys.get_state(LabelOrchestrator)
  end

  defp add_worker(id) do
    update(%{issues: [%Issue{id: id, identifier: "GH-#{id}", state: "ready", dispatchable: true, labels: ["ready"]}]})

    {:ok, worker} =
      Task.Supervisor.start_child(LabelTasks, fn ->
        receive do
          :finish -> :ok
        end
      end)

    :sys.replace_state(LabelOrchestrator, fn state ->
      entry = %{
        pid: worker,
        ref: Process.monitor(worker),
        identifier: "GH-#{id}",
        issue: %Issue{id: id, identifier: "GH-#{id}", state: "ready", dispatchable: true, labels: ["ready"]},
        started_at: DateTime.utc_now()
      }

      %{state | running: Map.put(state.running, id, entry), claimed: MapSet.put(state.claimed, id)}
    end)

    worker
  end

  defp write_github_workflow(repo \\ "octo/repo") do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github
      provider:
        repo: #{repo}
        token: test-token
        state_source: labels
        managed_running_label: in-progress
      required_labels: [ready]
      active_states: [ready]
      terminal_states: [closed]
    polling:
      interval_ms: 3600000
    agent:
      max_concurrent_agents: 1
    ---
    Test.
    """)

    WorkflowStore.force_reload()
    assert :ok = Config.validate!()
    assert Config.settings!().tracker.kind == "github"
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
