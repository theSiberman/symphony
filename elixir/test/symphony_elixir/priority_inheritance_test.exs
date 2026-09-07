defmodule SymphonyElixir.PriorityInheritanceTest do
  use SymphonyElixir.TestSupport

  defp issue(id, day, options \\ []) do
    struct!(
      %Issue{
        id: id,
        identifier: "GH-#{id}",
        title: id,
        state: "Todo",
        dispatchable: true,
        created_at: DateTime.add(~U[2026-01-01 00:00:00Z], day, :day)
      },
      options
    )
  end

  defp edge(id, state \\ "Todo"), do: %{"id" => 999_999, "identifier" => "GH-#{id}", "state" => state}
  defp order(issues), do: issues |> Orchestrator.sort_issues_for_dispatch_for_test() |> Enum.map(& &1.id)

  test "transitive blockers inherit oldest position without becoming dispatchable" do
    a = issue("1", 0, dispatchable: false, blocked_by: [edge("2")])
    b = issue("2", 3, dispatchable: false, blocked_by: [edge("3")])
    c = issue("3", 4)
    unrelated = issue("4", 1)
    assert order([unrelated, c, b, a]) == ["1", "2", "3", "4"]
    assert order([a, b, c, unrelated]) == ["1", "2", "3", "4"]
    sorted = Orchestrator.sort_issues_for_dispatch_for_test([unrelated, c, b, a])
    assert Enum.filter(sorted, & &1.dispatchable) == [c, unrelated]
    assert order([%{a | blocked_by: []}, %{b | blocked_by: []}, c, unrelated]) == ["1", "4", "2", "3"]
  end

  test "shared blockers inherit the best priority and preserve original tie breaks" do
    urgent = issue("1", 4, priority: 1, blocked_by: [edge("3"), edge("4")])
    old = issue("2", 0, priority: 2, blocked_by: [edge("3")])
    shared = issue("3", 5)
    sibling = issue("4", 3)
    assert order([shared, old, urgent, sibling]) == ["1", "4", "3", "2"]
  end

  test "cycles terminate and can promote a runnable dependency outside the cycle" do
    a = issue("1", 0, blocked_by: [edge("2")])
    b = issue("2", 3, blocked_by: [edge("1"), edge("3")])
    assert order([issue("4", 1), issue("3", 4), b, a]) == ["1", "2", "3", "4"]
  end

  test "terminal, paused and out of scope sources cannot donate or relay priority" do
    target = issue("3", 5)
    unrelated = issue("4", 2)

    for excluded <- [issue("2", 1, state: "Done"), issue("2", 1, state: "Paused"), issue("2", 1, priority_inheritable: false)] do
      excluded = %{excluded | blocked_by: [edge("3")]}
      a = issue("1", 0, blocked_by: [edge("2")])
      sorted = order([target, unrelated, excluded, a])
      assert Enum.find_index(sorted, &(&1 == "4")) < Enum.find_index(sorted, &(&1 == "3"))
    end

    assert order([target, unrelated, issue("1", 0, blocked_by: [edge("3", "Done")])]) == ["1", "4", "3"]
  end

  test "unknown identifiers cannot fall back to colliding database ids; canonical ids work" do
    target = issue("3", 5)
    unrelated = issue("4", 2)
    donor = issue("1", 0, blocked_by: [%{id: "3", identifier: "GH-missing"}])
    assert order([target, donor, unrelated]) == ["1", "4", "3"]
    assert order([target, %{donor | blocked_by: [%{id: "3"}]}, unrelated]) == ["1", "3", "4"]
    assert order([target, %{donor | blocked_by: [edge("1")]}, unrelated]) == ["1", "4", "3"]
  end

  test "required label exclusion prevents inheritance" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["ready"])
    donor = issue("1", 0, blocked_by: [edge("3")])
    target = issue("3", 5, labels: ["ready"])
    unrelated = issue("4", 2, labels: ["ready"])
    assert order([target, donor, unrelated]) == ["1", "4", "3"]
  end
end
