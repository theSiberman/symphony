defmodule SymphonyElixir.IntegrationTarget do
  @moduledoc """
  Selects the repository branch family that a tracker issue integrates into.

  The workspace provisioner resolves `branch` to exactly one remote ref and records its exact
  commit before an agent starts.
  """

  alias SymphonyElixir.Tracker.Issue

  @type kind :: :main | :parent_spec
  @type t :: %{kind: kind(), branch: String.t(), parent_number: pos_integer() | nil}

  @type child_policy :: :main | :parent_spec | String.t()

  @spec for_issue(Issue.t() | map() | term(), child_policy()) :: t()
  def for_issue(issue, child_policy \\ :main) do
    labels = normalized_labels(issue)

    cond do
      "integration:main" in labels -> main_target(issue)
      "integration:parent" in labels -> parent_target(issue)
      child_policy in [:main, "main"] -> main_target(issue)
      true -> parent_target(issue)
    end
  end

  defp normalized_labels(%{labels: labels}) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
  end

  defp normalized_labels(_issue), do: []

  defp main_target(issue) do
    %{kind: :main, branch: "main", parent_number: parent_number(issue)}
  end

  defp parent_target(%{native_ref: %{"parent_number" => parent_number}})
       when is_integer(parent_number) and parent_number > 0,
       do: %{kind: :parent_spec, branch: "spec/#{parent_number}-*", parent_number: parent_number}

  defp parent_target(_issue), do: %{kind: :main, branch: "main", parent_number: nil}

  defp parent_number(%{native_ref: %{"parent_number" => parent_number}})
       when is_integer(parent_number) and parent_number > 0,
       do: parent_number

  defp parent_number(_issue), do: nil
end
