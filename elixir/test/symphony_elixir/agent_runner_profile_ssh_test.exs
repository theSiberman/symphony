defmodule SymphonyElixir.AgentRunnerProfileSSHTest do
  use SymphonyElixir.TestSupport

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    trace = Path.join(root, "ssh-trace")
    remote = "/remote/symphony-local-fixture-#{System.unique_integer([:positive])}/GH-2120"
    fake_ssh = Path.join(root, "ssh")
    original_path = System.get_env("PATH")
    System.put_env("PATH", root <> ":" <> original_path)
    on_exit(fn -> restore_env("PATH", original_path) end)

    # This executable is the only SSH edge. It never invokes SSH or a network.
    File.write!(fake_ssh, """
    #!/bin/sh
    case "$*" in
      *__SYMPHONY_WORKSPACE__*)
        printf '%s\\t0\\t%s\\n' '__SYMPHONY_WORKSPACE__' '#{remote}' ;;
      *profile-before-hook*) printf 'before\\n' >> '#{trace}' ;;
      *profile-after-hook*) printf 'after\\n' >> '#{trace}' ;;
      *app-server*)
        printf 'session\\n' >> '#{trace}'
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1) printf '%s\\n' '{"id":1,"result":{}}' ;;
            3) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"ssh-thread"}}}' ;;
            4)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"ssh-turn"}}}'
              printf '%s\\n' '{"method":"turn/completed"}'
              exit 0 ;;
          esac
        done ;;
    esac
    """)

    File.chmod!(fake_ssh, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/remote/symphony-local-fixture",
      worker_ssh_hosts: ["fixture-only-host"],
      hook_before_run: "profile-before-hook",
      hook_after_run: "profile-after-hook",
      codex_command: "fixture-codex app-server"
    )

    issue = %Issue{id: "2120", identifier: "GH-2120", state: "In Progress", dispatchable: true}
    %{remote: remote, trace: trace, issue: issue}
  end

  test "an unprofiled SSH worker runs without a local copy of its workspace", context do
    refute File.exists?(context.remote)
    assert :ok = AgentRunner.run(context.issue, nil, worker_host: "fixture-only-host", max_turns: 1, issue_state_fetcher: fn _ids -> {:ok, []} end)
    assert File.read!(context.trace) == "before\nsession\nafter\n"
    refute File.exists?(context.remote)
  end

  test "a profiled SSH worker is refused before before_run or model startup", context do
    route = %{"profile" => "sol", "reason" => "label: profile:sol", "kind" => "codex", "model" => "gpt-6.1-sol", "effort" => "high", "command" => "fixture-codex app-server"}
    command = "printf '%s' '" <> Jason.encode!(route) <> "'"
    text = File.read!(Workflow.workflow_file_path())
    File.write!(Workflow.workflow_file_path(), String.replace(text, "agent:\n", "agent:\n  profile_command: #{Jason.encode!(command)}\n"))
    assert :ok = Config.validate!()

    assert catch_exit(AgentRunner.run(context.issue, nil, worker_host: "fixture-only-host")) ==
             {:agent_failed, :remote_execution_profile_unsupported}

    assert File.read!(context.trace) == "after\n"
    refute File.exists?(context.remote)
  end
end
