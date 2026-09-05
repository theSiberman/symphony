defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Issues-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.{AgentTool, Client, RunningLabels}
  alias SymphonyElixir.Tracker.Issue

  @active_states ["open"]
  @terminal_states ["closed"]

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    with :ok <- validate_active_states(tracker_settings),
         :ok <- validate_terminal_states(tracker_settings),
         :ok <- RunningLabels.validate_config(tracker_settings) do
      Client.validate_settings(tracker_settings)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @spec bind_running_labels(map()) :: map() | nil
  def bind_running_labels(settings), do: RunningLabels.bind(settings)

  @spec reconcile_running_labels(map(), [String.t()]) :: :ok | {:error, term()}
  def reconcile_running_labels(settings, ids) do
    client = client_module()
    RunningLabels.reconcile(settings, ids, &client.request/5)
  end

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: Client.secret_environment_names(tracker_settings)

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end

  defp validate_active_states(%{active_states: states} = settings) do
    if label_state_source?(settings) do
      validate_label_states(states, :missing_github_active_states, false)
    else
      validate_states(states, @active_states, :missing_github_active_states)
    end
  end

  defp validate_terminal_states(%{terminal_states: states} = settings) do
    if label_state_source?(settings) do
      validate_label_states(states, :missing_github_terminal_states, true)
    else
      validate_states(states, @terminal_states, :missing_github_terminal_states)
    end
  end

  defp validate_label_states(states, _missing_error, allow_closed?) when is_list(states) do
    valid? =
      Enum.all?(states, fn state ->
        normalized = normalize_state(state)
        normalized != "" and (allow_closed? or normalized != "closed")
      end)

    if valid?, do: :ok, else: {:error, :invalid_github_states}
  end

  defp validate_label_states(_states, missing_error, _allow_closed?), do: {:error, missing_error}

  defp label_state_source?(%{provider: provider}) when is_map(provider),
    do: provider["state_source"] == "labels"

  defp label_state_source?(_settings), do: false

  defp validate_states(states, allowed_states, _missing_error) when is_list(states) do
    if Enum.all?(states, &(normalize_state(&1) in allowed_states)) do
      :ok
    else
      {:error, :invalid_github_states}
    end
  end

  defp validate_states(_states, _allowed_states, missing_error), do: {:error, missing_error}

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
