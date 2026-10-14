defmodule SymphonyElixir.RunningLabelsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{RunningLabelLedger, RunningLabels}

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
    eventually(fn -> labels() == MapSet.new() end)
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

  describe "ledger ownership (shared label)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "symphony-ledger-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      %{path: Path.join(dir, "running-labels.json")}
    end

    test "exclusive ownership (explicit or default) still removes every unowned marker", %{path: path} do
      update(%{labels: MapSet.new([10, 1])})
      exclusive = put_in(settings(), [:provider, "managed_running_label_ownership"], "exclusive")
      exclusive = put_in(exclusive, [:provider, "managed_running_label_ledger_path"], path)
      assert :ok = RunningLabels.validate_config(exclusive)
      assert nil == RunningLabels.guard(exclusive)
      assert :ok = RunningLabels.reconcile(exclusive, ["2"], &GitHub.request/5)
      assert labels() == MapSet.new([2])
      refute File.exists?(path)
    end

    test "never removes foreign labels; removes and forgets own stopped labels; drops stale entries", %{path: path} do
      settings = ledger_settings(path)
      :ok = RunningLabelLedger.write(path, scope(), ["1", "2", "4"])
      update(%{labels: MapSet.new([10, 1, 2])})

      assert :ok = RunningLabels.reconcile(settings, ["2", "3"], &GitHub.request/5)
      assert labels() == MapSet.new([10, 2, 3])
      assert {:ok, ledger} = RunningLabelLedger.read(path, scope())
      assert ledger == MapSet.new(["2", "3"])
      refute Enum.any?(calls(), fn {method, path, _, _} -> method == "DELETE" and String.contains?(path, "/10/") end)

      assert :ok = RunningLabels.reconcile(settings, [], &GitHub.request/5)
      assert labels() == MapSet.new([10])
      assert {:ok, ledger} = RunningLabelLedger.read(path, scope())
      assert ledger == MapSet.new()
    end

    test "own label already gone at DELETE time (404) is forgotten", %{path: path} do
      :ok = RunningLabelLedger.write(path, scope(), ["1"])
      update(%{labels: MapSet.new([1])})

      request = fn
        "DELETE", _path, _params, _body, _opts -> {:ok, %{status: 404, body: %{}}}
        method, path, params, body, opts -> GitHub.request(method, path, params, body, opts)
      end

      assert :ok = RunningLabels.reconcile(ledger_settings(path), [], request)
      assert {:ok, ledger} = RunningLabelLedger.read(path, scope())
      assert ledger == MapSet.new()
    end

    test "records additions before POST so failed or crashed additions are retried or cleaned up", %{path: path} do
      settings = ledger_settings(path)
      test_pid = self()

      failing = fn
        "POST", _path, _params, _body, _opts ->
          send(test_pid, {:ledger_at_post, RunningLabelLedger.read(path, scope())})
          {:ok, %{status: 502, body: %{}}}

        method, path, params, body, opts ->
          GitHub.request(method, path, params, body, opts)
      end

      assert {:error, {:running_label_http_status, 502}} = RunningLabels.reconcile(settings, ["3"], failing)
      assert_received {:ledger_at_post, {:ok, at_post}}
      assert MapSet.member?(at_post, "3")
      assert labels() == MapSet.new()
      assert {:ok, ledger} = RunningLabelLedger.read(path, scope())
      assert MapSet.member?(ledger, "3")

      assert :ok = RunningLabels.reconcile(settings, ["3"], &GitHub.request/5)
      assert labels() == MapSet.new([3])

      # A recorded addition whose POST never landed is forgotten once it stops running.
      :ok = RunningLabelLedger.write(path, scope(), ["3", "5"])
      assert :ok = RunningLabels.reconcile(settings, ["3"], &GitHub.request/5)
      assert {:ok, ledger} = RunningLabelLedger.read(path, scope())
      assert ledger == MapSet.new(["3"])
    end

    test "scope mismatch or corrupt ledger fails closed without requests", %{path: path} do
      update(%{labels: MapSet.new([1])})
      settings = ledger_settings(path)

      :ok = RunningLabelLedger.write(path, {"https://api.github.com", "other/repo", "in-progress"}, ["1"])
      assert {:error, :running_label_ledger_scope_mismatch} = RunningLabels.reconcile(settings, [], &GitHub.request/5)
      assert {:error, :running_label_ledger_scope_mismatch} = RunningLabels.guard(settings)

      File.write!(path, "{not json")
      assert {:error, :running_label_ledger_corrupt} = RunningLabels.reconcile(settings, ["2"], &GitHub.request/5)
      assert {:error, :running_label_ledger_corrupt} = RunningLabels.guard(settings)

      assert calls() == []
      assert labels() == MapSet.new([1])
    end

    test "validates ownership and ledger path", %{path: path} do
      assert :ok = RunningLabels.validate_config(ledger_settings(path))

      for {ownership, ledger_path, error} <- [
            {"shared", path, :invalid_github_managed_running_label_ownership},
            {"ledger", nil, :invalid_github_managed_running_label_ledger_path},
            {"ledger", "relative/ledger.json", :invalid_github_managed_running_label_ledger_path}
          ] do
        invalid = put_in(ledger_settings(ledger_path), [:provider, "managed_running_label_ownership"], ownership)
        assert {:error, ^error} = RunningLabels.validate_config(invalid)
      end

      no_label = update_in(ledger_settings(path), [:provider], &Map.delete(&1, "managed_running_label"))
      assert {:error, :invalid_github_managed_running_label_ownership} = RunningLabels.validate_config(no_label)

      binding = Tracker.bind_running_labels(ledger_settings(path))
      assert binding.ownership == {:ledger, path}
      refute Tracker.running_labels_compatible?(binding, settings())
    end

    test "foreign-labelled candidates are not dispatched; own-ledger labelled candidates are", %{path: path} do
      write_github_workflow("octo/repo", "    managed_running_label_ownership: ledger\n    managed_running_label_ledger_path: #{path}\n")
      :ok = RunningLabelLedger.write(path, scope(), ["42"])
      binding = Tracker.bind_running_labels(Config.settings!().tracker)

      state = %Orchestrator.State{
        max_concurrent_agents: 3,
        running_labels: binding,
        label_guard: Tracker.running_label_guard(binding),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
      }

      issue = fn id, labels ->
        %Issue{id: id, identifier: "GH-#{id}", title: "T", state: "ready", dispatchable: true, labels: labels}
      end

      refute Orchestrator.should_dispatch_issue_for_test(issue.("1354", ["ready", "In-Progress"]), state)
      assert Orchestrator.should_dispatch_issue_for_test(issue.("42", ["ready", "in-progress"]), state)
      assert Orchestrator.should_dispatch_issue_for_test(issue.("7", ["ready"]), state)

      File.write!(path, "corrupt")
      closed = %{state | label_guard: Tracker.running_label_guard(binding)}
      refute Orchestrator.should_dispatch_issue_for_test(issue.("7", ["ready"]), closed)
    end
  end

  defp ledger_settings(path) do
    settings()
    |> put_in([:provider, "managed_running_label_ownership"], "ledger")
    |> put_in([:provider, "managed_running_label_ledger_path"], path)
  end

  defp scope, do: {"https://api.github.com", "octo/repo", "in-progress"}

  defp start_runtime do
    opts = [name: LabelRuntime, task_supervisor_name: LabelTasks, orchestrator_name: LabelOrchestrator]
    start_supervised!({SymphonyElixir.AgentRuntimeSupervisor, opts})
  end

  defp poll do
    send(LabelOrchestrator, :run_poll_cycle)

    eventually(fn ->
      state = :sys.get_state(LabelOrchestrator)
      state.tracker_task == nil and state.label_task == nil and not state.poll_check_in_progress
    end)
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

  defp write_github_workflow(repo \\ "octo/repo", extra_provider \\ "") do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: github
      provider:
        repo: #{repo}
        token: test-token
        state_source: labels
        managed_running_label: in-progress
    #{extra_provider}  required_labels: [ready]
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
