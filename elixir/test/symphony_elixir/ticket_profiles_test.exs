defmodule SymphonyElixir.TicketProfilesTest do
  use SymphonyElixir.TestSupport

  defmodule RuntimeEndpoint do
    @behaviour Plug
    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, owner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      result =
        case {conn.method, conn.request_path} do
          {"POST", "/session"} ->
            %{"id" => "muse-session"}

          {"POST", "/session/muse-session/message"} ->
            send(owner, {:opencode_turn, self(), Jason.decode!(body)})
            receive do: (:release -> :ok)
            %{"info" => %{"role" => "assistant", "tokens" => %{"input" => 12, "output" => 4}}, "parts" => []}

          {"POST", "/session/muse-session/abort"} ->
            send(owner, :opencode_stopped)
            true
        end

      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(result))
    end
  end

  test "concurrent workers own different adapters and keep them through a global reload" do
    root = Path.dirname(Workflow.workflow_file_path())
    workspaces = Path.join(root, "workers")
    release = Path.join(root, "release")
    codex = Path.join(root, "codex.py")
    selector = Path.join(root, "selector.py")
    {:ok, server} = Bandit.start_link(plug: {RuntimeEndpoint, self()}, port: 0)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    File.write!(codex, """
    import json,pathlib,sys,time
    for line in sys.stdin:
      message=json.loads(line); method=message.get('method')
      if method=='initialize': print(json.dumps({'id':1,'result':{}}),flush=True)
      if method=='thread/start': print(json.dumps({'id':2,'result':{'thread':{'id':'sol-thread'}}}),flush=True)
      if method=='turn/start':
        pathlib.Path('codex-started').write_text(sys.argv[1])
        while not pathlib.Path(#{inspect(release)}).exists(): time.sleep(.01)
        print(json.dumps({'id':3,'result':{'turn':{'id':'sol-turn'}}}),flush=True)
        print(json.dumps({'method':'turn/completed'}),flush=True)
    """)

    File.write!(selector, """
    import json,sys
    issue=json.loads(sys.stdin.readline())
    muse='profile:muse' in issue['labels']
    print(json.dumps({'profile':'muse' if muse else 'sol','reason':'label: profile:muse' if muse else 'label: profile:sol',
      'kind':'opencode' if muse else 'codex','command':#{inspect("python3 " <> codex <> " gpt-6.1-sol")},
      'model':'meta/muse-spark-1.3-contributor' if muse else 'gpt-6.1-sol','effort':'xhigh' if muse else 'high'}))
    """)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspaces,
      codex_command: "python3 #{codex} wrong-global-model",
      hook_before_run: "printf '%s|%s' \"$ADAMA_EXECUTION_PROFILE\" \"$ADAMA_PROFILE_REASON\" > before-route",
      hook_after_run: "printf '%s|%s' \"$ADAMA_EXECUTION_PROFILE\" \"$ADAMA_PROFILE_REASON\" > after-route",
      opencode_base_url: "http://127.0.0.1:#{port}",
      opencode_workspace_runtime: false,
      opencode_mcp_url: nil
    )

    text = File.read!(Workflow.workflow_file_path())
    text = String.replace(text, "codex:\n", "opencode:\n  base_url: http://127.0.0.1:#{port}\n  model: meta/muse-spark-1.3-contributor\n  workspace_runtime: false\ncodex:\n")
    File.write!(Workflow.workflow_file_path(), String.replace(text, "agent:\n", "agent:\n  profile_command: #{Jason.encode!("python3 " <> selector)}\n"))
    assert :ok = Config.validate!()

    # The full normalized Issue carries real dispatch/claim metadata; only profile labels vary.
    source = Jason.decode!(File.read!(Path.expand("../fixtures/profiles/2120.json", __DIR__)))

    sol = %Issue{
      id: "2120",
      identifier: "GH-2120",
      title: source["title"],
      description: source["body"],
      url: source["url"],
      state: "In Progress",
      labels: ["profile:sol"],
      dispatchable: true,
      native_ref: %{number: 2120},
      assignee_id: "fixture-owner"
    }

    muse = %{sol | id: "2119", identifier: "GH-2119", labels: ["profile:muse"]}

    tasks =
      Enum.map([sol, muse], fn issue ->
        Task.async(fn ->
          try do
            AgentRunner.run(issue, nil, max_turns: 1, issue_state_fetcher: fn _ids -> {:ok, []} end)
          catch
            :exit, reason -> {:worker_failed, reason}
          end
        end)
      end)

    try do
      assert_receive {:opencode_turn, http_worker, body}, 5_000
      assert body["model"] == %{"providerID" => "meta", "modelID" => "muse-spark-1.3-contributor"}
      assert body["variant"] == "xhigh"
      assert eventually(fn -> File.exists?(Path.join(workspaces, "GH-2120/codex-started")) end)
      assert File.read!(Path.join(workspaces, "GH-2120/codex-started")) == "gpt-6.1-sol"
      assert Enum.all?(tasks, &Process.alive?(&1.pid))
      assert Config.settings!().agent.kind == "codex"

      # Reload to the other global runtime while both sessions are alive.
      File.write!(Workflow.workflow_file_path(), String.replace(File.read!(Workflow.workflow_file_path()), "agent:\n", "agent:\n  kind: opencode\n"))
      assert :ok = Config.validate!()
      File.write!(release, "release")
      send(http_worker, :release)
      Enum.each(tasks, &assert(:ok == Task.await(&1, 5_000)))
      assert_receive :opencode_stopped

      for {identifier, profile} <- [{"GH-2120", "sol"}, {"GH-2119", "muse"}], hook <- ["before", "after"] do
        assert File.read!(Path.join(workspaces, "#{identifier}/#{hook}-route")) == "#{profile}|label: profile:#{profile}"
      end
    after
      File.write!(release, "release")
      Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
      GenServer.stop(server)
    end
  end

  test "the scheduler accounts and exposes capabilities using the worker's pinned runtime" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    scheduler = start_supervised!({Orchestrator, name: ProfileAccountingScheduler})
    issue = %Issue{id: "2119", identifier: "GH-2119", state: "In Progress", dispatchable: true}

    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
      started_at: DateTime.utc_now(),
      steering_supported: true,
      last_codex_event: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil
    }

    :sys.replace_state(scheduler, &%{&1 | running: %{issue.id => entry}, claimed: MapSet.new([issue.id])})

    runtime_info = %{
      runtime_kind: "opencode",
      capabilities: %{steering: false, streams_progress: false},
      execution_profile: %{"profile" => "muse", "reason" => "predicted size: 300 lines / 4 files (small)"}
    }

    send(scheduler, {:worker_runtime_info, issue.id, runtime_info})
    info = %{"role" => "assistant", "tokens" => %{"input" => 12, "output" => 4}}
    update = %{event: :turn_completed, timestamp: DateTime.utc_now(), session_id: "muse-session", message: %{"info" => info}}
    send(scheduler, {:codex_worker_update, issue.id, update})

    snapshot = Orchestrator.snapshot(ProfileAccountingScheduler, 1_000)
    assert [running] = snapshot.running
    refute running.steering_supported
    assert running.codex_input_tokens == 12
    assert running.codex_output_tokens == 4
    assert running.codex_total_tokens == 16
    assert snapshot.codex_totals.input_tokens == 12
    assert snapshot.codex_totals.output_tokens == 4
    assert snapshot.codex_totals.total_tokens == 16
  end

  test "a timed-out selector stops its owned process before failing the worker" do
    root = Path.dirname(Workflow.workflow_file_path())
    selector = Path.join(root, "slow-selector.py")
    marker = Path.join(root, "selector-pid")
    File.write!(selector, "import os,pathlib,time\npathlib.Path(#{inspect(marker)}).write_text(str(os.getpid()))\ntime.sleep(60)\n")
    text = File.read!(Workflow.workflow_file_path())
    File.write!(Workflow.workflow_file_path(), String.replace(text, "agent:\n", "agent:\n  profile_command: #{Jason.encode!("python3 " <> selector)}\n"))
    assert :ok = Config.validate!()
    issue = %Issue{id: "2120", identifier: "GH-2120", labels: [], dispatchable: true}

    try do
      assert catch_exit(AgentRunner.run(issue)) == {:agent_failed, :execution_profile_selector_timeout}
      selector_pid = File.read!(marker)
      assert {_output, code} = System.cmd("kill", ["-0", selector_pid], stderr_to_stdout: true)
      assert code != 0, "timed-out selector survived worker teardown"
    after
      if File.exists?(marker), do: System.cmd("kill", ["-KILL", File.read!(marker)], stderr_to_stdout: true)
    end
  end

  test "an unprofiled attempt removes a prior per-Ticket receipt" do
    {:ok, root} = SymphonyElixir.PathSafety.canonicalize(Path.dirname(Workflow.workflow_file_path()))
    directory = Path.join(root, ".context")
    File.mkdir_p!(directory)
    receipt = Path.join(directory, "execution-profile.json")
    File.write!(receipt, Jason.encode!(%{"profile" => "muse", "reason" => "prior attempt"}))
    assert :ok = SymphonyElixir.ExecutionProfile.persist(root, nil)
    refute File.exists?(receipt)
    assert :ok = SymphonyElixir.ExecutionProfile.persist(root, nil)
    File.mkdir!(receipt)
    assert {:error, _reason} = SymphonyElixir.ExecutionProfile.persist(root, nil)
  end

  test "invalid or failed selector output cannot start a model or create its workspace" do
    root = Path.dirname(Workflow.workflow_file_path())
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(root, "uncreated"))
    original = File.read!(Workflow.workflow_file_path())
    issue = %Issue{id: "2120", identifier: "GH-2120", labels: [], dispatchable: true}

    for {command, expected} <- [
          {"printf invalid-json", :invalid_execution_profile_route},
          {"exit 7", {:execution_profile_selector_failed, 7}},
          {"printf '%s' '{\"profile\":\"unknown\",\"reason\":\"fixture\",\"kind\":\"unknown\",\"model\":\"fixture\",\"effort\":\"high\"}'", :invalid_execution_profile_route}
        ] do
      text = String.replace(original, "agent:\n", "agent:\n  profile_command: #{Jason.encode!(command)}\n")
      File.write!(Workflow.workflow_file_path(), text)
      assert :ok = Config.validate!()
      assert catch_exit(AgentRunner.run(issue)) == {:agent_failed, expected}
      refute File.exists?(Path.join(root, "uncreated/GH-2120"))
    end
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: check.()

  defp eventually(check, attempts) do
    if check.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(check, attempts - 1)
        )
  end
end
