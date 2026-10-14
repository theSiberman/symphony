defmodule SymphonyElixir.AgentHandoffTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.ResumeManifest
  alias SymphonyElixirWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-handoff-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/MT-HANDOFF")
    File.mkdir_p!(Path.join(workspace, ".context"))
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, workspace: workspace}
  end

  defp request do
    %{
      "request_id" => "operator-1",
      "expected_session_id" => "thread-owned-turn-owned",
      "expected_thread_id" => "thread-owned",
      "expected_turn_id" => "turn-owned",
      "text" => "Use the maintained verifier at the next safe boundary."
    }
  end

  defp issue, do: %Issue{id: "handoff-issue", identifier: "MT-HANDOFF", title: "Owned handoff", state: "In Progress", url: "https://example.org/issue"}

  defp configure(root, mode, overrides \\ []) do
    command = "#{System.find_executable("python3")} -I -B #{Path.expand("test/fixtures/handoff_app_server.py")} #{mode}"

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge([workspace_root: Path.join(root, "workspaces"), codex_command: command, codex_approval_policy: "never", codex_turn_timeout_ms: 2_000, poll_interval_ms: 60_000], overrides)
    )

    command
  end

  defp worker(workspace) do
    recipient = self()
    Task.async(fn -> AppServer.run(workspace, "continue", issue(), issue_identifier: "MT-HANDOFF", on_message: &send(recipient, {:update, &1})) end)
  end

  defp scheduler(worker) do
    name = Module.concat(__MODULE__, Scheduler)
    pid = start_supervised!({Orchestrator, name: name})

    :sys.replace_state(pid, fn state ->
      if is_reference(state.tick_timer_ref), do: Process.cancel_timer(state.tick_timer_ref)

      entry = %{
        pid: worker.pid,
        ref: Process.monitor(worker.pid),
        identifier: "MT-HANDOFF",
        issue: issue(),
        steering_supported: true,
        session_id: "thread-owned-turn-owned",
        started_at: DateTime.utc_now(),
        last_codex_timestamp: DateTime.utc_now(),
        codex_app_server_pid: nil,
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0,
        turn_count: 1,
        last_codex_message: nil,
        last_codex_event: nil
      }

      %{state | running: %{issue().id => entry}, claimed: MapSet.new([issue().id])}
    end)

    {pid, name}
  end

  defp wait_for_file(path, attempts \\ 100)

  defp wait_for_file(path, attempts) when attempts > 0 do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_for_file(path, attempts - 1)
        )
  end

  defp wait_for_file(_, 0), do: flunk("owned fixture did not reach protocol gate")

  defp endpoint(name) do
    original = Application.get_env(:symphony_elixir, Endpoint, [])
    Application.put_env(:symphony_elixir, Endpoint, Keyword.merge(original, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: name))
    start_supervised!({Endpoint, []})
    on_exit(fn -> Application.put_env(:symphony_elixir, Endpoint, original) end)
  end

  defp api(payload) do
    Plug.Test.conn(:post, "/api/v1/MT-HANDOFF/steer", Jason.encode!(payload))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Endpoint.call(Endpoint.init([]))
  end

  test "owned steer interleaves updates/approval, waits for native ACK, and deduplicates", %{root: root, workspace: workspace} do
    configure(root, "steer")
    task = worker(workspace)
    assert_receive {:update, %{event: :session_started}}, 1_000
    {_pid, name} = scheduler(task)
    endpoint(name)
    call = Task.async(fn -> api(request()) end)
    wait_for_file(Path.join(workspace, ".context/steer-received"))
    assert %{running: [_]} = Orchestrator.snapshot(name, 100)
    assert api(request()).status == 409
    refute Task.yield(call, 0)
    File.write!(Path.join(workspace, ".context/ack"), "ack")
    response = Task.await(call, 1_000)
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["accepted_turn_id"] == "turn-owned"
    assert api(request()).status == 200
    assert api(Map.put(request(), "text", "different instruction")).status == 409
    protocol = File.read!(Path.join(workspace, ".context/protocol.jsonl")) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(protocol, &(&1["method"] == "turn/steer")) == 1
    assert Enum.any?(protocol, &(&1["id"] == "approval-owned" and &1["result"] != nil))
    File.write!(Path.join(workspace, ".context/finish"), "done")
    assert {:ok, _} = Task.await(task, 1_000)
  end

  test "HTTP rejects malformed/stale/unsupported/dead requests before sending", %{root: root, workspace: workspace} do
    configure(root, "silent")
    task = worker(workspace)
    assert_receive {:update, %{event: :session_started}}, 1_000
    {pid, name} = scheduler(task)
    endpoint(name)
    assert {:error, :invalid_request} = Orchestrator.steer(name, "MT-HANDOFF", nil)

    for bad <- [%{}, Map.put(request(), "text", String.duplicate("x", 8_193)), Map.put(request(), "extra", true)] do
      assert api(bad).status == 400
    end

    assert api(Map.put(request(), "expected_session_id", "stale")).status == 409
    :sys.replace_state(pid, fn state -> put_in(state.running[issue().id].steering_supported, false) end)
    assert api(request()).status == 409
    :sys.replace_state(pid, fn state -> %{state | running: %{}} end)
    assert api(request()).status == 404
    assert Task.shutdown(task, :brutal_kill) == nil
  end

  test "provider disconnect returns delivery unknown without retrying", %{root: root, workspace: workspace} do
    configure(root, "disconnect")
    task = worker(workspace)
    assert_receive {:update, %{event: :session_started}}, 1_000
    {_pid, name} = scheduler(task)
    assert {:error, :delivery_unknown} = Orchestrator.steer(name, "MT-HANDOFF", request())
    assert {:error, :delivery_unknown} = Orchestrator.steer(name, "MT-HANDOFF", request())
    assert {:error, {:port_exit, 0}} = Task.await(task, 1_000)
  end

  test "inbox steering traffic cannot extend the existing provider silence deadline", %{root: root, workspace: workspace} do
    configure(root, "silent", codex_turn_timeout_ms: 120)
    task = worker(workspace)
    assert_receive {:update, %{event: :session_started}}, 1_000
    started = System.monotonic_time(:millisecond)

    recipient = self()
    flood = spawn(fn -> flood_steers(task.pid, recipient, started + 700) end)

    try do
      assert {:error, :turn_timeout} = Task.await(task, 300)
      assert Process.alive?(flood), "deadline must fire while control messages are still arriving"
      assert System.monotonic_time(:millisecond) - started < 300
    after
      Process.exit(flood, :kill)
    end
  end

  defp flood_steers(pid, recipient, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      send_flood_batch(pid, recipient)
      flood_steers(pid, recipient, deadline)
    end
  end

  defp send_flood_batch(pid, recipient) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, size} when size < 500 ->
        ref = make_ref()
        for _ <- 1..100, do: send(pid, {:agent_steer, recipient, ref, Map.put(request(), "expected_turn_id", "stale")})

      _ ->
        Process.sleep(1)
    end
  end

  defp artifact(path, bytes) do
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    %{"path" => path, "size" => byte_size(bytes), "sha256" => hash(bytes)}
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp resume_manifest(root, workspace, command) do
    snapshots = Path.join(root, "operator/snapshots")
    File.mkdir_p!(snapshots)
    File.chmod!(Path.dirname(snapshots), 0o700)
    File.chmod!(snapshots, 0o700)
    history = artifact(Path.join(snapshots, "rollout.jsonl"), Jason.encode!(%{type: "session_meta", payload: %{id: "thread-owned", cwd: workspace}}) <> "\n")
    databases = for name <- ["state_5.sqlite", "thread_history_1.sqlite"], do: Map.put(artifact(Path.join(snapshots, name), <<"SQLite format 3", 0, "owned fixture database">>), "name", name)

    entry = %{
      "issue_identifier" => "MT-HANDOFF",
      "workspace_path" => workspace,
      "thread_id" => "thread-owned",
      "handoff_text" => "Use the approved maintained verifier. Preserve the worktree and prior ticket work.",
      "profile" => %{"codex_command_sha256" => hash(command), "model" => "fixture-model", "model_provider" => "fixture-provider", "reasoning_effort" => "high"},
      "history" => history,
      "databases" => databases
    }

    manifest = %{"schema" => "symphony.codex-resume.v1", "state" => "ready", "entries" => [entry]}
    path = Path.join(root, "operator/resume.json")
    File.write!(path, Jason.encode!(manifest))
    File.chmod!(path, 0o600)
    {path, manifest}
  end

  test "explicit valid restart evidence uses thread resume and retains original thread", %{root: root, workspace: workspace} do
    command = configure(root, "resume")
    {path, _} = resume_manifest(root, workspace, command)
    configure(root, "resume", codex_resume_manifest_path: path)
    assert {:ok, session} = AppServer.start_session(workspace, issue_identifier: "MT-HANDOFF")
    assert session.thread_id == "thread-owned"
    assert {:ok, %{thread_id: "thread-owned"}} = AppServer.run_turn(session, "continue", issue())
    AppServer.stop_session(session)
    assert {:error, :resume_already_consumed} = AppServer.start_session(workspace, issue_identifier: "MT-HANDOFF")
    protocol = File.read!(Path.join(workspace, ".context/protocol.jsonl"))
    assert protocol =~ "thread/resume"
    refute protocol =~ "thread/start"
    assert {:ok, nil} = ResumeManifest.load(workspace <> "-NEW", "MT-NEW", Config.settings!().codex)
    records = protocol |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    turn = Enum.find(records, &(&1["method"] == "turn/start"))
    assert hd(turn["params"]["input"])["text"] =~ "approved maintained verifier"
  end

  test "resume refuses forged paths, missing/truncated history, wrong workspace/profile and prepared manifests", %{root: root, workspace: workspace} do
    command = configure(root, "resume")
    {path, manifest} = resume_manifest(root, workspace, command)
    settings = Map.put(Config.settings!().codex, :resume_manifest_path, path)
    [entry] = manifest["entries"]

    mutations = [
      Map.put(manifest, "state", "prepared"),
      Map.put(manifest, "entries", [Map.put(entry, "workspace_path", root)]),
      put_in(manifest, ["entries", Access.at(0), "profile", "codex_command_sha256"], hash("different command")),
      put_in(manifest, ["entries", Access.at(0), "history", "path"], "/etc/passwd"),
      put_in(manifest, ["entries", Access.at(0), "history", "path"], Path.join(root, "operator/snapshots/missing")),
      Map.put(manifest, "entries", [entry, entry])
    ]

    for changed <- mutations do
      File.write!(path, Jason.encode!(changed))
      assert {:error, _} = ResumeManifest.load(workspace, "MT-HANDOFF", settings)
    end

    File.write!(path, Jason.encode!(manifest))
    File.chmod!(path, 0o600)
    File.write!(entry["history"]["path"], "truncated")
    assert {:error, _} = ResumeManifest.load(workspace, "MT-HANDOFF", settings)
    configure(root, "resume", codex_resume_manifest_path: path)
    assert {:error, _} = AppServer.start_session(workspace, issue_identifier: "MT-HANDOFF")
    refute File.exists?(Path.join(workspace, ".context/protocol.jsonl"))
  end

  test "native resume mismatch never falls back to a fresh thread", %{root: root, workspace: workspace} do
    command = configure(root, "resume-wrong")
    {path, _} = resume_manifest(root, workspace, command)
    configure(root, "resume-wrong", codex_resume_manifest_path: path)
    assert {:error, :resumed_thread_mismatch} = AppServer.start_session(workspace, issue_identifier: "MT-HANDOFF")
    refute File.read!(Path.join(workspace, ".context/protocol.jsonl")) =~ "thread/start"
    refute File.exists?(Path.join(root, "operator/consumed"))
  end

  test "resume control files and artifacts require protected ownership and permissions", %{root: root, workspace: workspace} do
    command = configure(root, "resume")
    {path, manifest} = resume_manifest(root, workspace, command)
    settings = Map.put(Config.settings!().codex, :resume_manifest_path, path)
    [entry] = manifest["entries"]

    history_path = entry["history"]["path"]
    paths = [{path, 0o600}, {Path.dirname(path), 0o700}, {history_path, 0o600}, {Path.dirname(history_path), 0o700}]

    for {unprotected, protected_mode} <- paths do
      File.chmod!(unprotected, 0o777)
      assert {:error, _} = ResumeManifest.load(workspace, "MT-HANDOFF", settings)
      File.chmod!(unprotected, protected_mode)
    end

    assert {:ok, _} = ResumeManifest.load(workspace, "MT-HANDOFF", settings)
  end

  test "changed operator evidence between validation and ACK cannot publish consumption", %{root: root, workspace: workspace} do
    command = configure(root, "resume")
    {path, manifest} = resume_manifest(root, workspace, command)
    configure(root, "resume", codex_resume_manifest_path: path)
    assert {:ok, entry} = ResumeManifest.load(workspace, "MT-HANDOFF", Config.settings!().codex)
    File.write!(path, Jason.encode!(Map.put(manifest, "state", "prepared")))
    assert {:error, :resume_evidence_changed} = ResumeManifest.consume(entry)
    refute File.exists?(Path.join(root, "operator/consumed"))
  end
end
