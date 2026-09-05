defmodule SymphonyElixir.IntegrationTarget do
  @moduledoc """
  Selects the repository branch family that a tracker issue integrates into.

  The workspace provisioner resolves `branch` to exactly one remote ref and records its exact
  commit before an agent starts.
  """

  alias SymphonyElixir.Tracker.Issue

  @type kind :: :main | :parent_spec
  @type t :: %{kind: kind(), branch: String.t(), parent_number: pos_integer() | nil}

  @spec for_issue(Issue.t() | map() | term()) :: t()
  def for_issue(%{native_ref: %{"parent_number" => parent_number}})
      when is_integer(parent_number) and parent_number > 0,
      do: %{kind: :parent_spec, branch: "spec/#{parent_number}-*", parent_number: parent_number}

  def for_issue(_issue), do: %{kind: :main, branch: "main", parent_number: nil}
end
