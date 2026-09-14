defmodule SymphonyElixir.IntegrationTargetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.IntegrationTarget
  alias SymphonyElixir.Tracker.Issue

  test "parent issue uses its integration branch unless explicitly routed to main" do
    issue = %Issue{native_ref: %{"parent_number" => 226}, labels: []}

    assert IntegrationTarget.for_issue(issue) == %{
             kind: :parent_spec,
             branch: "spec/226-*",
             parent_number: 226
           }

    assert IntegrationTarget.for_issue(%{issue | labels: ["Integration:Main"]}) == %{
             kind: :main,
             branch: "main",
             parent_number: 226
           }
  end
end
