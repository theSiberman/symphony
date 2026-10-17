defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, IntegrationTarget, PathSafety, SSH, Tracker}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @doc "Validated completed provisioning identity; dirty source is permitted."
  @spec resume_identity(map()) :: map() | nil
  def resume_identity(issue) do
    workspace = Path.join(Config.local_workspace_root(), workspace_key(issue))
    marker = Path.join(workspace, ".scratch/ownership.json")

    with {:ok, canonical} <- PathSafety.canonicalize(marker),
         true <- canonical == marker,
         {:ok, content} <- File.read(marker),
         {:ok, %{"version" => 1, "workspace" => ^workspace, "identifier" => identifier, "git_dir" => git_dir} = identity} <- Jason.decode(content),
         true <- identifier == issue.identifier,
         true <- valid_provisioning?(workspace, identity),
         {actual, 0} <- System.cmd("git", ["-C", workspace, "rev-parse", "--absolute-git-dir"], stderr_to_stdout: true),
         true <- String.trim(actual) == git_dir,
         {:ok, %{uid: uid}} <- File.stat(Config.local_workspace_root()),
         {:ok, %{uid: ^uid}} <- File.stat(marker),
         {:ok, %{uid: ^uid} = stat} <- File.stat(workspace) do
      %{
        workspace: workspace,
        git_dir: git_dir,
        inode: stat.inode,
        provisioning_hash: :crypto.hash(:sha256, content) |> Base.encode16(),
        target_inode: target_inode(Path.join(workspace, "target"))
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp valid_provisioning?(workspace, identity) do
    with %{"branch" => branch, "integration_branch" => integration_branch, "integration_commit" => commit, "required_paths" => [_ | _] = paths} <- identity,
         true <- Enum.all?([branch, integration_branch, commit], &(is_binary(&1) and &1 != "")),
         true <- Enum.all?(paths, &provisioning_artifact?(workspace, &1, get_in(identity, ["required_types", &1]))),
         {actual_branch, 0} <- System.cmd("git", ["-C", workspace, "branch", "--show-current"]),
         true <- String.trim(actual_branch) == branch,
         {actual_integration, 0} <- System.cmd("git", ["-C", workspace, "config", "--local", "symphony.integrationBranch"]),
         true <- String.trim(actual_integration) == integration_branch,
         {actual_commit, 0} <- System.cmd("git", ["-C", workspace, "config", "--local", "symphony.integrationCommit"]),
         {_, 0} <- System.cmd("git", ["-C", workspace, "merge-base", "--is-ancestor", commit, String.trim(actual_commit)], stderr_to_stdout: true),
         {_, 0} <- System.cmd("git", ["-C", workspace, "merge-base", "--is-ancestor", commit, "HEAD"], stderr_to_stdout: true) do
      true
    else
      _ -> false
    end
  end

  defp provisioning_artifact?(workspace, relative, expected_type) when is_binary(relative) do
    path = Path.join(workspace, relative)

    with true <- relative != "" and Path.type(relative) == :relative and ".." not in Path.split(relative),
         {:ok, ^path} <- PathSafety.canonicalize(path),
         {:ok, %{uid: uid}} <- File.stat(workspace),
         {:ok, %{uid: ^uid, type: type}} <- File.stat(path),
         true <- {expected_type, type} in [{"file", :regular}, {"directory", :directory}] do
      true
    else
      _ -> false
    end
  end

  defp provisioning_artifact?(_, _, _), do: false

  defp target_inode(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory, inode: inode}} -> inode
      _ -> nil
    end
  end

  # These markers exist only while an exhausted-worker hold is being written to
  # the tracker. They also cover failures before a ticket checkout exists.
  @spec record_exception(map(), String.t(), map()) :: :ok | {:error, term()}
  def record_exception(issue, reason, scope), do: record_exception(issue, reason, scope, :reporter)

  @spec record_exception(map(), String.t(), map(), :reporter | :operator) :: :ok | {:error, term()}
  def record_exception(issue, reason, scope, audience) when audience in [:reporter, :operator] do
    with {:ok, directory} <- exception_directory(),
         :ok <- File.mkdir_p(directory) do
      path = Path.join(directory, workspace_key(issue) <> ".json")

      with :ok <- validate_local_workspace_path(path, directory) do
        File.write(
          path,
          Jason.encode!(%{
            id: issue.id,
            identifier: issue.identifier,
            reason: reason,
            scope: scope,
            audience: audience
          }),
          [:sync]
        )
      end
    end
  end

  @spec pending_exceptions() :: {:ok, [map()]} | {:error, term()}
  def pending_exceptions do
    with {:ok, directory} <- exception_directory() do
      case File.ls(directory) do
        {:error, :enoent} -> {:ok, []}
        {:error, reason} -> {:error, reason}
        {:ok, files} -> read_exceptions(directory, files)
      end
    end
  end

  @spec clear_exception(map()) :: :ok | {:error, term()}
  def clear_exception(issue) do
    with {:ok, directory} <- exception_directory() do
      File.rm(Path.join(directory, workspace_key(issue) <> ".json"))
    end
  end

  defp exception_directory do
    root = Config.local_workspace_root()
    directory = Path.join(root, ".symphony-exceptions")
    with :ok <- validate_local_workspace_path(directory, root), do: {:ok, directory}
  end

  defp read_exceptions(directory, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, entries} ->
      path = Path.join(directory, file)

      with :ok <- validate_local_workspace_path(path, directory),
           {:ok, content} <- File.read(path),
           {:ok, %{"id" => id, "identifier" => identifier, "reason" => reason} = entry} <- Jason.decode(content),
           true <-
             is_binary(id) and is_binary(identifier) and is_binary(reason) and
               Map.get(entry, "audience", "reporter") in ["reporter", "operator"] do
        {:cont, {:ok, [entry | entries]}}
      else
        error -> {:halt, {:error, {:pending_exception_unreadable, path, error}}}
      end
    end)
  end

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = workspace_key(issue_or_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host) do
        with :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
          {:ok, workspace}
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        with :ok <- validate_provisioning_marker(workspace) do
          {:ok, workspace, File.exists?(provisioning_path(workspace))}
        end

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        ~s{marker="$(dirname "$workspace")/.symphony-provisioning/$(basename "$workspace")"},
        ~s{if [ -L "$(dirname "$marker")" ] || [ -L "$marker" ]; then exit 1; fi},
        "if [ -d \"$workspace\" ] && [ ! -e \"$marker\" ]; then",
        "  created=0",
        "else",
        "  created=1",
        ~s{  mkdir -p "$(dirname "$marker")"; touch "$marker"},
        "  if [ -e \"$workspace\" ] && [ ! -d \"$workspace\" ]; then rm -rf \"$workspace\"; fi",
        "  mkdir -p \"$workspace\"",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    marker = provisioning_path(workspace)

    with :ok <- validate_provisioning_marker(workspace),
         :ok <- File.mkdir_p(Path.dirname(marker)),
         :ok <- File.write(marker, "pending\n", [:sync]),
         :ok <- File.mkdir_p(workspace) do
      {:ok, workspace, true}
    end
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            remove_local_workspace(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @doc false
  @spec remove_recorded(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, nil) when is_binary(workspace) do
    if Path.type(workspace) == :absolute do
      case validate_recorded_workspace_path(workspace) do
        :ok ->
          remove_local_workspace(workspace)

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}
    end
  end

  def remove_recorded(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    remove(workspace, worker_host)
  end

  def remove_recorded(workspace, _worker_host) do
    {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}
  end

  defp remove_local_workspace(workspace) do
    result =
      case maybe_run_before_remove_hook(workspace, nil) do
        :ok -> File.rm_rf(workspace)
        {:error, reason} -> {:error, reason, workspace}
      end

    case result do
      {:ok, _} ->
        File.rm(cleanup_record_path(workspace))
        clear_provisioning(workspace, nil)

      {:error, reason, _} ->
        persist_cleanup(workspace, reason)
        Logger.warning("Workspace cleanup pending workspace=#{workspace} reason=#{inspect(reason)}")
    end

    result
  end

  defp persist_cleanup(workspace, reason) do
    path = cleanup_record_path(workspace)
    temporary = path <> ".new"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, canonical} <- PathSafety.canonicalize(temporary),
         true <- canonical == temporary,
         :ok <- File.write(temporary, Jason.encode!(%{workspace: workspace, error: inspect(reason)}), [:sync]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error -> Logger.error("Unable to persist workspace cleanup workspace=#{workspace} reason=#{inspect(error)}")
    end
  end

  @doc "Retry failed removals only after positive current terminal-state confirmation."
  @spec reconcile_cleanup() :: :ok
  def reconcile_cleanup do
    settings = Config.settings!()
    records = Config.local_workspace_root() |> Path.join(".symphony-cleanup/*.json") |> Path.wildcard()

    if records != [] do
      states = settings.tracker.terminal_states

      case Tracker.fetch_issues_by_states(states) do
        {:ok, issues} ->
          terminal_states = MapSet.new(states, &String.downcase/1)

          terminal =
            issues
            |> Enum.filter(&MapSet.member?(terminal_states, String.downcase(&1.state)))
            |> MapSet.new(&Path.join(Config.local_workspace_root(), workspace_key(&1)))

          Enum.each(records, &retry_current_cleanup(&1, terminal, settings))

        {:error, reason} ->
          Logger.warning("Preserving pending workspace cleanup reason=#{inspect(reason)}")
      end
    end

    :ok
  end

  @doc "Discovers terminal workspaces left behind after a ticket left the scheduler queue."
  @spec reconcile_terminal_workspaces([map()]) :: :ok
  def reconcile_terminal_workspaces(active_issues \\ []) when is_list(active_issues) do
    settings = Config.settings!()
    terminal_states = settings.tracker.terminal_states
    active_workspaces = MapSet.new(active_issues, &workspace_path_for_issue_key/1)

    case Tracker.fetch_issues_by_states(terminal_states) do
      {:ok, issues} ->
        terminal_state_set = MapSet.new(terminal_states, &String.downcase/1)

        issues
        |> Enum.filter(&terminal_issue?(&1, terminal_state_set))
        |> Enum.reject(&MapSet.member?(active_workspaces, workspace_path_for_issue_key(&1)))
        |> Enum.each(&remove_current_terminal_workspace(&1, settings))

      {:error, reason} ->
        Logger.warning("Skipping terminal workspace reconciliation; failed to fetch terminal issues: #{inspect(reason)}")
    end

    :ok
  end

  defp retry_current_cleanup(record, terminal, settings) do
    if settings == Config.settings!(), do: retry_cleanup(record, terminal)
  end

  defp remove_current_terminal_workspace(issue, settings) do
    # A slow tracker response can cross a workflow reload. Its terminal
    # observations must never clean a workspace using the new settings.
    if settings == Config.settings!(), do: remove_clean_terminal_workspace(issue)
  end

  defp terminal_issue?(%{state: state}, terminal_states) when is_binary(state),
    do: MapSet.member?(terminal_states, String.downcase(state))

  defp terminal_issue?(_, _terminal_states), do: false

  defp workspace_path_for_issue_key(%{identifier: identifier}) when is_binary(identifier) do
    Path.join(Config.local_workspace_root(), workspace_key(identifier))
  end

  defp workspace_path_for_issue_key(_issue), do: nil

  # Periodic discovery has no worker lifecycle to establish ownership of a
  # workspace. Delete only work whose branch is reachable and fully pushed;
  # tracked or untracked source changes, malformed checkouts, and failed checks
  # are preserved for an operator to inspect. Only the known generated roots
  # target, node_modules, .scratch, and terminal .context output are disposable.
  defp remove_clean_terminal_workspace(%{identifier: identifier} = issue) when is_binary(identifier) do
    case Config.settings!().worker.ssh_hosts do
      [] -> remove_clean_local_terminal_workspace(issue)
      worker_hosts -> remove_clean_remote_terminal_workspaces(issue, worker_hosts)
    end
  end

  defp remove_clean_terminal_workspace(_issue), do: :ok

  defp remove_clean_local_terminal_workspace(issue) do
    workspace = workspace_path_for_issue_key(issue)
    # Historical terminal issues normally have no checkout. Avoid a bounded
    # `git -C` timeout and a misleading preservation log for each absent path.
    if File.exists?(workspace) and clean_git_workspace?(workspace), do: remove(workspace)
  end

  defp remove_clean_remote_terminal_workspaces(issue, worker_hosts) do
    Enum.each(worker_hosts, fn worker_host ->
      with {:ok, workspace} <- workspace_path_for_issue(workspace_key(issue), worker_host),
           true <- clean_remote_git_workspace?(workspace, worker_host) do
        remove(workspace, worker_host)
      else
        _ -> :ok
      end
    end)
  end

  defp clean_git_workspace?(workspace) when is_binary(workspace) do
    case run_git(workspace, ["status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching"]) do
      {status, 0} -> clean_published_git_workspace?(workspace, status)
      _ -> preserve_terminal_workspace(workspace, :git_status_failed)
    end
  rescue
    _ -> preserve_terminal_workspace(workspace, :git_status_failed)
  end

  defp clean_published_git_workspace?(workspace, status) do
    with :ok <- disposable_workspace_status?(status),
         {branch, 0} when branch != "" <- run_git(workspace, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
         {head, 0} <- run_git(workspace, ["rev-parse", "HEAD"]),
         {remote_head, 0} <- run_git(workspace, ["ls-remote", "--exit-code", "origin", "refs/heads/#{branch}"]),
         true <- remote_branch_head?(remote_head, head) do
      true
    else
      :source_changes -> preserve_terminal_workspace(workspace, :source_changes)
      {:unknown_ignored_path, path} -> preserve_terminal_workspace(workspace, {:unknown_ignored_path, path})
      _ -> preserve_terminal_workspace(workspace, :unpublished_or_remote_unreachable)
    end
  end

  defp disposable_workspace_status?(""), do: :ok

  defp disposable_workspace_status?(status) do
    status
    |> String.split("\n", trim: true)
    |> Enum.reduce_while(:ok, fn
      "!! " <> ignored_path, :ok ->
        if disposable_ignored_path?(ignored_path),
          do: {:cont, :ok},
          else: {:halt, {:unknown_ignored_path, ignored_path}}

      generated_latest_json, :ok ->
        if generated_latest_json?(generated_latest_json),
          do: {:cont, :ok},
          else: {:halt, :source_changes}
    end)
  end

  defp disposable_ignored_path?(path) do
    case Path.split(path) do
      [".gsd", "test-runs" | _] -> true
      [root | _] -> root in ["target", "node_modules", ".scratch", ".context"]
      [] -> false
    end
  end

  defp generated_latest_json?(<<index, worktree, " ", ".gsd/test-runs/latest.json">>) do
    index in [?\s, ?M] and worktree in [?\s, ?M] and {index, worktree} != {?\s, ?\s}
  end

  defp generated_latest_json?(_status), do: false

  defp preserve_terminal_workspace(workspace, reason) do
    Logger.info("Preserving terminal workspace workspace=#{workspace} reason=#{inspect(reason)}")
    false
  end

  defp run_git(workspace, arguments) do
    case System.cmd("timeout", ["--kill-after=1s", "15s", "git", "-C", workspace | arguments], stderr_to_stdout: true) do
      {output, status} -> {String.trim_trailing(output), status}
    end
  end

  defp remote_branch_head?(remote_head, head) do
    case String.split(remote_head, ~r/\s+/, trim: true) do
      [^head, _ref] -> true
      _ -> false
    end
  end

  defp clean_remote_git_workspace?(workspace, worker_host) do
    script =
      [
        remote_shell_assign("workspace", workspace),
        "status=$(git -C \"$workspace\" status --porcelain=v1 --untracked-files=all --ignored=matching) || exit 1",
        "if printf '%s\\n' \"$status\" | grep -Ev '^!! (target|node_modules|\\.scratch|\\.context)(/|$)' | grep -q .; then exit 1; fi",
        "branch=$(git -C \"$workspace\" symbolic-ref --quiet --short HEAD) || exit 1",
        "head=$(git -C \"$workspace\" rev-parse HEAD) || exit 1",
        "remote=$(git -C \"$workspace\" ls-remote --exit-code origin \"refs/heads/$branch\") || exit 1",
        "test \"${remote%%[[:space:]]*}\" = \"$head\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {"", 0}} -> true
      _ -> false
    end
  end

  defp retry_cleanup(path, terminal) do
    with {:ok, canonical} <- PathSafety.canonicalize(path),
         true <- canonical == path,
         {:ok, content} <- File.read(path),
         {:ok, %{"workspace" => workspace}} <- Jason.decode(content),
         true <- path == cleanup_record_path(workspace),
         true <- MapSet.member?(terminal, workspace) do
      case remove(workspace) do
        {:ok, _} -> File.rm(path)
        _ -> :ok
      end
    else
      reason -> Logger.warning("Preserving pending workspace cleanup record=#{path} reason=#{inspect(reason)}")
    end
  end

  defp cleanup_record_path(workspace) do
    key = :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower)
    Path.join([Config.local_workspace_root(), ".symphony-cleanup", key <> ".json"])
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, worker_host)
      when is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(issue), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, nil) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(issue), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue, &1))
    end

    :ok
  end

  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(identifier), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(identifier), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.local_workspace_root()
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  @doc """
  Returns the collision-safe directory name for an issue identifier.

  The hash is derived from the original identifier so callers that only know the identifier can
  derive the same key as callers holding a full tracker issue.
  """
  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = safe_identifier(identifier)

    if safe_identifier == identifier do
      safe_identifier
    else
      "#{safe_identifier}--#{short_identifier_hash(identifier)}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  defp safe_identifier(identifier) when is_binary(identifier),
    do: String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

  defp short_identifier_hash(identifier) do
    :crypto.hash(:sha256, identifier)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp provisioning_path(workspace) do
    Path.join([Path.dirname(workspace), ".symphony-provisioning", Path.basename(workspace)])
  end

  defp validate_provisioning_marker(workspace) do
    marker = provisioning_path(workspace)

    with :ok <- validate_local_workspace_path(marker, Config.local_workspace_root()),
         {:ok, ^marker} <- PathSafety.canonicalize(marker) do
      :ok
    else
      _ -> {:error, {:workspace_provisioning_marker_unsafe, marker}}
    end
  end

  defp maybe_run_after_create_hook(_workspace, _issue_context, false, _worker_host), do: :ok

  defp maybe_run_after_create_hook(workspace, issue_context, true, worker_host) do
    result =
      case Config.settings!().hooks.after_create do
        nil -> :ok
        command -> run_hook(command, workspace, issue_context, "after_create", worker_host)
      end

    # Never remove a partial checkout: its separate Git objects, dirty source,
    # and failure evidence must survive. The marker makes retries complete the
    # hook instead of admitting a partially provisioned agent workspace.
    with :ok <- result do
      clear_provisioning(workspace, worker_host)
    end
  end

  defp clear_provisioning(workspace, nil) do
    with :ok <- validate_provisioning_marker(workspace) do
      case File.rm(provisioning_path(workspace)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:workspace_provisioning_marker_failed, reason}}
      end
    end
  end

  defp clear_provisioning(workspace, worker_host) do
    case run_remote_command(worker_host, "rm -f #{shell_escape(provisioning_path(workspace))}", Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} -> :ok
      result -> {:error, {:workspace_provisioning_marker_failed, result}}
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    transcript = hook_transcript_path(workspace, hook_name)
    File.write!(transcript, "")
    File.chmod!(transcript, 0o600)

    task = Task.async(fn -> capture_hook(command, workspace, issue_context, transcript) end)

    result =
      case Task.yield(task, timeout_ms) do
        {:ok, status} ->
          handle_hook_command_result({File.read!(transcript), status}, workspace, issue_context, hook_name, transcript)

        nil ->
          send(task.pid, :hook_timeout)
          if Task.yield(task, 100) == nil, do: Task.shutdown(task, :brutal_kill)
          persist_hook_transcript(transcript, File.read!(transcript))
          Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms} diagnostics=#{transcript}")
          {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
      end

    if result == :ok, do: File.rm(transcript)
    result
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms
    remote_command = hook_environment_script(issue_context) <> "\nexport SYMPHONY_HOOK_TIMEOUT_MS=#{Config.settings!().hooks.timeout_ms}\n" <> command

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(
           worker_host,
           "cd #{shell_escape(workspace)} && #{remote_command}",
           timeout_ms
         ) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp capture_hook(command, workspace, issue_context, transcript) do
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["-lc", command]},
        {:cd, workspace},
        {:env,
         Enum.map(hook_environment(issue_context) ++ [{"SYMPHONY_HOOK_TIMEOUT_MS", Integer.to_string(Config.settings!().hooks.timeout_ms)}], fn {key, value} ->
           {String.to_charlist(key), String.to_charlist(value)}
         end)}
      ])

    collect_hook_output(port, transcript, "")
  end

  defp collect_hook_output(port, transcript, pending) do
    receive do
      {^port, {:data, data}} ->
        lines = String.split(pending <> data, "\n")
        {complete, [pending]} = Enum.split(lines, -1)
        if complete != [], do: File.write!(transcript, redact_hook_output(Enum.join(complete, "\n") <> "\n"), [:append])
        collect_hook_output(port, transcript, pending)

      {^port, {:exit_status, status}} ->
        File.write!(transcript, redact_hook_output(pending), [:append, :sync])
        status

      :hook_timeout ->
        File.write!(transcript, redact_hook_output(pending), [:append, :sync])
        Port.close(port)
        :timeout
    end
  end

  defp handle_hook_command_result(result, workspace, issue_context, hook_name) do
    handle_hook_command_result(result, workspace, issue_context, hook_name, nil)
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name, _transcript), do: :ok

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name, transcript) do
    transcript = transcript || hook_transcript_path(workspace, hook_name)
    redacted = persist_hook_transcript(transcript, output)
    sanitized_output = sanitize_hook_output_for_log(redacted)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} diagnostics=#{transcript} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, redacted}}
  end

  defp hook_transcript_path(workspace, hook_name) do
    directory = Path.join(Config.local_workspace_root(), ".symphony-hook-logs")
    path = Path.join(directory, "#{Path.basename(workspace)}-#{hook_name}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.log")
    :ok = validate_local_workspace_path(path, Config.local_workspace_root())
    File.mkdir_p!(directory)
    path
  end

  defp persist_hook_transcript(path, output) do
    redacted = redact_hook_output(IO.iodata_to_binary(output))
    File.write!(path, redacted, [:sync])
    File.chmod!(path, 0o600)
    redacted
  end

  defp redact_hook_output(output) do
    tracker = Config.settings!().tracker

    environment_secrets =
      System.get_env()
      |> Enum.filter(fn {key, value} ->
        String.match?(key, ~r/(TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY|CREDENTIAL)/i) and byte_size(value) >= 4
      end)
      |> Enum.map(fn {_key, value} -> value end)

    output =
      [tracker.api_key, tracker.provider["token"] | environment_secrets]
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(fn value -> [value | String.split(value, "\n")] end)
      |> Enum.filter(&(byte_size(&1) >= 4))
      |> Enum.uniq()
      |> Enum.sort_by(&(-byte_size(&1)))
      |> Enum.reduce(output, fn value, result -> String.replace(result, value, "[REDACTED]") end)

    output
    |> String.replace(~r/((?:authorization|_authToken|password|api[_-]?key|access[_-]?token)\s*[:=]\s*)(?:Bearer\s+|Basic\s+)?[^\s"']+/i, "\\1[REDACTED]")
    |> String.replace(~r{(https?://)[^/@\s]+:[^/@\s]+@}, "\\1[REDACTED]@")
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Config.local_workspace_root())
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp validate_recorded_workspace_path(workspace) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Path.dirname(workspace))
  end

  defp validate_local_workspace_path(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#\\~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    build_issue_context(issue_id, identifier, integration_target(issue))
    |> Map.put(:execution_profile, Map.get(issue, :execution_profile))
  end

  defp issue_context(identifier) when is_binary(identifier) do
    build_issue_context(nil, identifier, integration_target(nil))
  end

  defp issue_context(_identifier) do
    build_issue_context(nil, "issue", integration_target(nil))
  end

  defp integration_target(issue) do
    IntegrationTarget.for_issue(issue, Config.settings!().tracker.child_integration_target)
  end

  defp build_issue_context(issue_id, issue_identifier, integration_target) do
    %{
      issue_id: issue_id,
      issue_identifier: issue_identifier || "issue",
      issue_parent_number: integration_target.parent_number,
      integration_branch: integration_target.branch
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end

  defp hook_environment(issue_context) when is_map(issue_context) do
    issue_id = Map.get(issue_context, :issue_id)
    issue_identifier = Map.get(issue_context, :issue_identifier)
    parent_number = Map.get(issue_context, :issue_parent_number)
    integration_branch = Map.get(issue_context, :integration_branch, "main")

    route = Map.get(issue_context, :execution_profile) || %{}
    profile_env = if route == %{}, do: [], else: [{"ADAMA_EXECUTION_PROFILE", route["profile"]}, {"ADAMA_PROFILE_REASON", route["reason"]}]

    profile_env ++
      [
        {"SYMPHONY_OWNER_PID", System.pid()},
        {"SYMPHONY_ISSUE_ID", issue_id || ""},
        {"SYMPHONY_ISSUE_IDENTIFIER", issue_identifier || "issue"},
        {"SYMPHONY_ISSUE_PARENT_NUMBER", if(is_integer(parent_number), do: Integer.to_string(parent_number), else: "")},
        {"SYMPHONY_INTEGRATION_BRANCH", integration_branch}
      ]
  end

  defp hook_environment_script(issue_context) do
    hook_environment(issue_context)
    |> Enum.map_join("\n", fn {name, value} -> "export #{name}=#{shell_escape(value)}" end)
  end
end
