defmodule SymphonyElixir.FailurePauseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Memory

  defmodule OfflineGitHub do
    def request(method, path, _params, body, _opts) do
      send(self(), {:request, method, path, body})
      status = Process.get({:status, method}, 200)
      {:ok, %{status: status, body: %{}}}
    end

    def fetch_issues_by_states(_), do: {:ok, []}
    def fetch_issues_by_ids(_), do: {:ok, []}
  end

  setup do
    original = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, OfflineGitHub)

    on_exit(fn ->
      if original,
        do: Application.put_env(:symphony_elixir, :github_client_module, original),
        else: Application.delete_env(:symphony_elixir, :github_client_module)
    end)

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
    ---
    Test only.
    """)

    WorkflowStore.force_reload()
    %{issue: %Issue{id: "17", identifier: "GH-17", state: "ready-for-agent", labels: ["ready-for-agent", "bug"]}}
  end

  test "persists exception without replacing unrelated labels", %{issue: issue} do
    assert :ok = Tracker.pause_issue(issue, "worker OOM")
    assert_receive {:request, "POST", "/repos/fixture/offline/issues/17/labels", %{"labels" => ["needs-info"]}}
    assert_receive {:request, "DELETE", "/repos/fixture/offline/issues/17/labels/ready-for-agent", nil}
    assert_receive {:request, "POST", "/repos/fixture/offline/issues/17/comments", %{"body" => body}}
    assert body =~ "worker OOM"
  end

  test "operator failures use an operator-facing hold instead of needs-info", %{issue: issue} do
    assert :ok = Tracker.pause_issue(issue, "integration target selector resolved 0 branches", :operator)

    assert_receive {:request, "POST", "/repos/fixture/offline/issues/17/labels",
                    %{
                      "labels" => ["needs-triage"]
                    }}

    assert_receive {:request, "DELETE", "/repos/fixture/offline/issues/17/labels/ready-for-agent", nil}
    assert_receive {:request, "POST", "/repos/fixture/offline/issues/17/comments", %{"body" => body}}
    assert body =~ "operator"
    refute body =~ "reporter"
  end

  test "captured hold settings keep mutations on the original repository after reload", %{issue: issue} do
    settings = Config.settings!().tracker
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert :ok = Tracker.pause_issue(issue, "worker OOM", :reporter, settings)
    assert_receive {:request, "POST", "/repos/fixture/offline/issues/17/labels", _}
    assert_receive {:request, "DELETE", "/repos/fixture/offline/issues/17/labels/ready-for-agent", nil}
    assert_receive {:request, "POST", "/repos/fixture/offline/issues/17/comments", _}
  end

  test "a failed exception write is visible and stops further mutation", %{issue: issue} do
    Process.put({:status, "POST"}, 503)
    assert {:error, {:pause_failed, _}} = Tracker.pause_issue(issue, "worker OOM")
    assert_receive {:request, "POST", _, _}
    refute_receive {:request, "DELETE", _, _}
  end

  test "an already removed queue label is idempotent", %{issue: issue} do
    Process.put({:status, "DELETE"}, 404)
    assert :ok = Tracker.pause_issue(issue, "worker OOM")
    assert_receive {:request, "POST", "/repos/fixture/offline/issues/17/comments", _}
  end

  test "memory adapter retains its reporter-facing compatibility entry point" do
    issue = %Issue{id: "memory-17", identifier: "MEM-17", state: "ready", labels: ["ready"]}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert :ok = Memory.pause_issue(issue, "worker OOM")

    assert [%Issue{state: "needs-info", labels: ["needs-info"]}] =
             Application.fetch_env!(:symphony_elixir, :memory_tracker_issues)

    assert :ok = Tracker.pause_issue(issue, "operator repair", :operator, %{kind: "memory"})
    assert [%Issue{state: "needs-triage"}] = Application.fetch_env!(:symphony_elixir, :memory_tracker_issues)
  end

  test "trackers without hold support report both pause entry points as unsupported", %{issue: issue} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    assert {:error, :tracker_pause_unsupported} = Tracker.pause_issue(issue, "worker OOM")

    assert {:error, :tracker_pause_unsupported} =
             Tracker.pause_issue(issue, "broken provisioning policy", :operator)

    assert {:error, :tracker_pause_unsupported} =
             Tracker.pause_issue(issue, "broken provisioning policy", :operator, Config.settings!().tracker)
  end
end
