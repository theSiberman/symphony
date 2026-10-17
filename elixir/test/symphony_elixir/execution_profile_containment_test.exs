defmodule SymphonyElixir.ExecutionProfileContainmentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{ExecutionProfile, PathSafety}

  setup do
    {:ok, root} = PathSafety.canonicalize(Path.dirname(Workflow.workflow_file_path()))
    %{root: root}
  end

  @route %{
    "profile" => "sol",
    "reason" => "label: profile:sol",
    "kind" => "codex",
    "model" => "gpt-6.1-sol",
    "effort" => "high",
    "command" => "codex app-server"
  }

  for operation <- [:write, :remove], link <- [:context, :receipt] do
    test "#{operation} rejects a linked #{link} and preserves the owned outside file", %{root: root} do
      workspace = Path.join(root, "workspace")
      outside = Path.join(root, "outside")
      File.mkdir_p!(workspace)
      File.mkdir_p!(outside)
      target = Path.join(outside, "execution-profile.json")
      File.write!(target, "preserve outside fixture\n")
      context = Path.join(workspace, ".context")
      receipt = Path.join(context, "execution-profile.json")

      if unquote(link) == :context do
        File.ln_s!(outside, context)
      else
        File.mkdir!(context)
        File.ln_s!(target, receipt)
      end

      route = if unquote(operation) == :write, do: @route, else: nil
      result = ExecutionProfile.persist(workspace, route)
      assert File.read(target) == {:ok, "preserve outside fixture\n"}
      assert {:error, _reason} = result
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(if(unquote(link) == :context, do: context, else: receipt))
    end
  end

  test "a non-directory workspace is rejected before creating a receipt", %{root: root} do
    workspace = Path.join(root, "not-a-directory")
    File.write!(workspace, "preserve workspace fixture")
    assert {:error, _reason} = ExecutionProfile.persist(workspace, @route)
    assert File.read!(workspace) == "preserve workspace fixture"
  end

  test "receipt inspection propagates real filesystem permission errors", %{root: root} do
    workspace = Path.join(root, "workspace")
    context = Path.join(workspace, ".context")
    File.mkdir_p!(context)
    File.chmod!(context, 0o000)

    try do
      assert {:error, :eacces} = ExecutionProfile.persist(workspace, @route)
      assert {:error, :eacces} = ExecutionProfile.persist(workspace, nil)
    after
      File.chmod!(context, 0o700)
    end

    assert File.ls!(context) == []
  end
end
