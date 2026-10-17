defmodule SymphonyElixir.ExecutionProfile do
  @moduledoc "Resolves the deployment-owned routing command once per worker attempt."

  alias SymphonyElixir.{AgentRuntime, Config, PathSafety}

  @spec resolve(map()) :: {:ok, map() | nil} | {:error, term()}
  def resolve(issue) do
    case Config.settings!().agent.profile_command do
      nil -> {:ok, nil}
      command -> run_selector(command, issue)
    end
  end

  def persist(workspace, route, worker_host \\ nil)

  @spec persist(Path.t(), map() | nil, String.t() | nil) :: :ok | {:error, term()}
  def persist(_workspace, nil, worker_host) when is_binary(worker_host), do: :ok
  def persist(_workspace, _route, worker_host) when is_binary(worker_host), do: {:error, :remote_execution_profile_unsupported}

  def persist(workspace, nil, nil) do
    with {:ok, receipt} <- receipt_path(workspace) do
      remove_receipt(receipt)
    end
  end

  def persist(workspace, route, nil) do
    with {:ok, receipt} <- receipt_path(workspace),
         :ok <- File.mkdir_p(Path.dirname(receipt)) do
      File.write(receipt, Jason.encode!(route))
    end
  end

  defp remove_receipt(receipt) do
    case File.rm(receipt) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp receipt_path(workspace) do
    workspace = Path.expand(workspace)
    directory = Path.join(workspace, ".context")
    receipt = Path.join(directory, "execution-profile.json")

    with {:ok, %{type: :directory}} <- File.lstat(workspace),
         {:ok, ^workspace} <- PathSafety.canonicalize(workspace),
         :ok <- unlinked_receipt_path(directory),
         :ok <- unlinked_receipt_path(receipt),
         {:ok, ^directory} <- PathSafety.canonicalize(directory),
         {:ok, ^receipt} <- PathSafety.canonicalize(receipt) do
      {:ok, receipt}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :unsafe_execution_profile_receipt}
    end
  end

  defp unlinked_receipt_path(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> {:error, :unsafe_execution_profile_receipt}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec session_options(map() | nil) :: keyword()
  def session_options(nil), do: []
  def session_options(%{"kind" => "codex"} = route), do: [runtime_kind: "codex", command: route["command"]]

  def session_options(%{"kind" => "opencode"} = route) do
    settings = %{Config.settings!().opencode | model: route["model"], variant: route["effort"]}
    [runtime_kind: "opencode", settings: settings]
  end

  defp run_selector(command, issue) do
    # Ticket text is data in an environment value, never interpolated shell code.
    payload = issue |> Map.from_struct() |> Map.drop([:execution_profile]) |> Jason.encode!()

    # The same process-group owner as host admission reaps the command even if
    # the worker exits. Killing only an Elixir task leaves its shell children.
    case System.cmd("timeout", ["--kill-after=1s", "10s", "sh", "-c", "printf '%s\\n' \"$SYMPHONY_TICKET_JSON\" | #{command}"], env: [{"SYMPHONY_TICKET_JSON", payload}]) do
      {output, 0} -> decode(output)
      {_output, 124} -> {:error, :execution_profile_selector_timeout}
      {_output, status} -> {:error, {:execution_profile_selector_failed, status}}
    end
  end

  defp decode(output) do
    with {:ok, %{} = route} <- Jason.decode(output),
         true <- Enum.all?(["profile", "reason", "kind", "model", "effort"], &(is_binary(route[&1]) and String.trim(route[&1]) != "")),
         {:ok, _adapter} <- AgentRuntime.adapter_for_kind(route["kind"]),
         true <- route["kind"] != "codex" or (is_binary(route["command"]) and String.trim(route["command"]) != "") do
      {:ok, route}
    else
      _ -> {:error, :invalid_execution_profile_route}
    end
  end
end
