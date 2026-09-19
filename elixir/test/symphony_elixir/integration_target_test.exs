defmodule SymphonyElixir.IntegrationTargetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.IntegrationTarget
  alias SymphonyElixir.Tracker.Issue

  test "child issue defaults to main unless explicitly routed to its parent" do
    issue = %Issue{native_ref: %{"parent_number" => 226}, labels: []}

    assert IntegrationTarget.for_issue(issue) == %{
             kind: :main,
             branch: "main",
             parent_number: 226
           }

    assert IntegrationTarget.for_issue(%{issue | labels: ["Integration:Main"]}) == %{
             kind: :main,
             branch: "main",
             parent_number: 226
           }

    assert IntegrationTarget.for_issue(%{issue | labels: ["Integration:Parent"]}) == %{
             kind: :parent_spec,
             branch: "spec/226-*",
             parent_number: 226
           }
  end

  test "workflow policy can route child issues to main with an explicit parent override" do
    issue = %Issue{native_ref: %{"parent_number" => 534}, labels: []}

    assert IntegrationTarget.for_issue(issue, :main) == %{
             kind: :main,
             branch: "main",
             parent_number: 534
           }

    assert IntegrationTarget.for_issue(%{issue | labels: ["Integration:Parent"]}, :main) == %{
             kind: :parent_spec,
             branch: "spec/534-*",
             parent_number: 534
           }

    assert IntegrationTarget.for_issue(%Issue{}, :main) == %{
             kind: :main,
             branch: "main",
             parent_number: nil
           }
  end

  test "legacy workflow policy must explicitly opt into parent integration" do
    issue = %Issue{native_ref: %{"parent_number" => 225}, labels: []}

    assert IntegrationTarget.for_issue(issue, :parent_spec) == %{
             kind: :parent_spec,
             branch: "spec/225-*",
             parent_number: 225
           }

    assert IntegrationTarget.for_issue(%Issue{}, :parent_spec) == %{
             kind: :main,
             branch: "main",
             parent_number: nil
           }
  end
end
