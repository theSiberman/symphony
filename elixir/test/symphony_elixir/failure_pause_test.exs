defmodule SymphonyElixir.FailurePauseTest do
  use SymphonyElixir.TestSupport

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
end
