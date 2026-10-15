defmodule SymphonyElixir.GitHub.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.GitHub.AgentTool, as: GitHubAgentTool
  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.GitHub.HttpCache

  defmodule FakeGitHubClient do
    def fetch_issues_by_states(states) do
      send(self(), {:github_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:github_ids_called, ids})
      {:ok, ids}
    end
  end

  setup do
    github_client_module = Application.get_env(:symphony_elixir, :github_client_module)

    on_exit(fn ->
      if is_nil(github_client_module) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, github_client_module)
      end
    end)

    :ok
  end

  test "adapter validates GitHub config, delegates reads, and advertises github_api" do
    settings = tracker_settings()

    assert :ok = GitHubAdapter.validate_config(settings)

    assert {:error, :missing_github_active_states} =
             GitHubAdapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_github_terminal_states} =
             GitHubAdapter.validate_config(%{settings | terminal_states: nil})

    assert :ok = GitHubAdapter.validate_config(%{settings | active_states: [], terminal_states: []})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: ["Todo"]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: [42]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | active_states: ["closed"]})

    assert {:error, :invalid_github_states} =
             GitHubAdapter.validate_config(%{settings | terminal_states: ["open"]})

    assert :ok =
             GitHubAdapter.validate_config(%{
               tracker_settings(%{"state_source" => "labels"})
               | active_states: ["ready-for-agent", "in-progress"],
                 terminal_states: ["closed", "ready-for-human", "needs-info", "wontfix"]
             })

    assert {:error, :missing_github_active_states} =
             GitHubAdapter.validate_config(%{
               tracker_settings(%{"state_source" => "labels"})
               | active_states: nil,
                 terminal_states: ["closed"]
             })

    assert {:error, :missing_github_repo} =
             GitHubAdapter.validate_config(%{
               kind: "github",
               active_states: ["open"],
               terminal_states: ["closed"]
             })

    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    assert {:ok, ["open"]} = GitHubAdapter.fetch_issues_by_states(["open"])
    assert_receive {:github_states_called, ["open"]}

    assert {:ok, ["42"]} = GitHubAdapter.fetch_issues_by_ids(["42"])
    assert_receive {:github_ids_called, ["42"]}

    assert [%{"name" => "github_api"}] = GitHubAdapter.agent_tool_specs()

    assert GitHubAdapter.execute_agent_tool(
             "github_api",
             %{"method" => "GET", "path" => "/user"},
             github_client: fn _method, _path, _params, _body, _opts ->
               {:ok, %{status: 200, body: %{"login" => "octocat"}}}
             end
           )["success"]
  end

  test "client validates repository settings and declares token environments" do
    assert :ok = GitHubClient.validate_settings(tracker_settings())

    assert {:error, :missing_github_repo} =
             GitHubClient.validate_settings(tracker_settings(%{"repo" => 123}))

    assert {:error, :invalid_github_repo} =
             GitHubClient.validate_settings(tracker_settings(%{"repo" => "not-a-repo"}))

    assert {:error, :missing_github_token} =
             GitHubClient.validate_settings(tracker_settings(%{"token" => 123}))

    assert {:error, :invalid_github_api_url} =
             GitHubClient.validate_settings(tracker_settings(%{"api_url" => "not a url"}))

    assert {:error, :invalid_github_api_url} =
             GitHubClient.validate_settings(tracker_settings(%{"api_url" => "http://api.github.com"}))

    assert {:error, :invalid_github_spec_issue_number} =
             GitHubClient.validate_settings(tracker_settings(%{"spec_issue_number" => "42"}))

    assert GitHubClient.secret_environment_names(tracker_settings(%{"token" => "$SYMPHONY_GITHUB_TOKEN"})) == [
             "GITHUB_TOKEN",
             "GH_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN",
             "GH_ENTERPRISE_TOKEN",
             "SYMPHONY_GITHUB_TOKEN"
           ]
  end

  test "client normalizes GitHub issues without dropping provider details" do
    issue = GitHubClient.normalize_issue_for_test(raw_issue(42), "octo/repo")

    assert issue.id == "42"
    assert issue.identifier == "GH-42"

    assert issue.native_ref == %{
             "id" => 1_042,
             "node_id" => "I_42",
             "number" => 42,
             "repo" => "octo/repo"
           }

    assert issue.title == "Issue 42"
    assert issue.description == "Body 42"
    assert issue.state == "open"
    assert issue.url == "https://github.test/octo/repo/issues/42"
    assert issue.assignee_id == "octocat"
    assert issue.labels == ["bug", "platform"]
    assert issue.blocked_by == []
    assert issue.dispatchable
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at

    refute GitHubClient.normalize_issue_for_test(
             Map.put(raw_issue(43), "pull_request", %{"url" => "https://api.github.test/pulls/43"}),
             "octo/repo"
           ).dispatchable

    assert GitHubClient.normalize_issue_for_test(
             Map.put(raw_issue(44), "title", " "),
             "octo/repo"
           ) == nil
  end

  test "client pages state reads, filters requested states, and drops malformed records" do
    first_page =
      Enum.map(1..97, &raw_issue/1) ++
        [
          Map.put(raw_issue(98), "pull_request", %{"url" => "https://api.github.test/pulls/98"}),
          Map.put(raw_issue(99), "state", "closed"),
          Map.put(raw_issue(100), "title", "")
        ]

    request_fun = fn "GET", "/repos/octo/repo/issues", params, nil, settings ->
      send(self(), {:github_page, params, settings})

      body =
        case params["page"] do
          1 -> first_page
          2 -> [raw_issue(101)]
        end

      {:ok, %{status: 200, body: body}}
    end

    log =
      capture_log(fn ->
        assert {:ok, issues} =
                 GitHubClient.fetch_issues_by_states_for_test(
                   [" OPEN "],
                   tracker_settings(),
                   request_fun
                 )

        assert length(issues) == 99
        assert hd(issues).id == "1"
        assert List.last(issues).id == "101"
        refute Enum.any?(issues, &(&1.id == "99"))
        assert Enum.find(issues, &(&1.id == "98")).dispatchable == false
      end)

    assert log =~ "Dropping malformed GitHub issue records count=1"

    assert_receive {:github_page,
                    %{
                      "state" => "open",
                      "per_page" => 100,
                      "page" => 1,
                      "sort" => "created",
                      "direction" => "asc"
                    }, %{repo: "octo/repo"}}

    assert_receive {:github_page, %{"page" => 2}, %{repo: "octo/repo"}}

    assert {:ok, []} =
             GitHubClient.fetch_issues_by_states_for_test(
               ["In Progress"],
               tracker_settings(),
               fn _method, _path, _params, _body, _settings ->
                 flunk("unsupported GitHub states should not make an HTTP request")
               end
             )
  end

  test "client refreshes numeric IDs in order, omits 404s, and rejects malformed refreshes" do
    request_fun = fn "GET", path, %{}, nil, _settings ->
      send(self(), {:github_id_path, path})

      case path do
        "/repos/octo/repo/issues/2" -> {:ok, %{status: 200, body: raw_issue(2)}}
        "/repos/octo/repo/issues/1" -> {:ok, %{status: 200, body: raw_issue(1)}}
        "/repos/octo/repo/issues/404" -> {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
      end
    end

    assert {:ok, issues} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["2", "1", "404", "2"],
               tracker_settings(),
               request_fun
             )

    assert Enum.map(issues, & &1.id) == ["2", "1"]
    assert_receive {:github_id_path, "/repos/octo/repo/issues/2"}
    assert_receive {:github_id_path, "/repos/octo/repo/issues/1"}
    assert_receive {:github_id_path, "/repos/octo/repo/issues/404"}
    refute_receive {:github_id_path, "/repos/octo/repo/issues/2"}

    assert {:error, :invalid_github_issue_id} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["not-a-number"],
               tracker_settings(),
               request_fun
             )

    assert {:error, :github_unknown_payload} =
             GitHubClient.fetch_issues_by_ids_for_test(
               ["3"],
               tracker_settings(),
               fn _method, _path, _params, _body, _settings ->
                 {:ok, %{status: 200, body: Map.put(raw_issue(3), "title", "")}}
               end
             )
  end

  test "label-state polling exposes structure and marks issues with open blockers non-dispatchable" do
    request_fun = fn
      "GET", "/repos/octo/repo/issues", %{"labels" => label}, nil, _settings ->
        assert label in ["ready-for-agent", "in-progress"]
        {:ok, %{status: 200, body: [raw_issue(42), raw_issue(43)]}}

      "GET", "/repos/octo/repo/issues/42", %{}, nil, _settings ->
        {:ok, %{status: 200, body: Map.put(raw_issue(42), "parent_issue_url", "https://api.github.test/repos/octo/repo/issues/7")}}

      "GET", "/repos/octo/repo/issues/42/parent", %{}, nil, _settings ->
        {:ok, %{status: 200, body: raw_issue(7)}}

      "GET", "/repos/octo/repo/issues/43", %{}, nil, _settings ->
        {:ok, %{status: 200, body: Map.put(raw_issue(43), "parent_issue_url", nil)}}

      "GET", "/repos/octo/repo/issues/43/parent", %{}, nil, _settings ->
        {:ok, %{status: 404, body: %{"message" => "No parent issue found"}}}

      "GET", "/repos/octo/repo/issues/42/sub_issues", %{}, nil, _settings ->
        {:ok, %{status: 200, body: []}}

      "GET", "/repos/octo/repo/issues/43/sub_issues", %{}, nil, _settings ->
        {:ok, %{status: 200, body: [raw_issue(44)]}}

      "GET", "/repos/octo/repo/issues/42/dependencies/blocked_by", %{"page" => 1, "per_page" => 100}, nil, _settings ->
        {:ok, %{status: 200, body: []}}

      "GET", "/repos/octo/repo/issues/43/dependencies/blocked_by", %{"page" => 1, "per_page" => 100}, nil, _settings ->
        {:ok, %{status: 200, body: [raw_issue(41)]}}
    end

    settings = %{
      tracker_settings(%{"state_source" => "labels"})
      | active_states: ["ready-for-agent", "in-progress"],
        terminal_states: ["closed", "ready-for-human", "needs-info", "wontfix"]
    }

    assert {:ok, issues} =
             GitHubClient.fetch_issues_by_states_for_test(
               settings.active_states,
               settings,
               request_fun
             )

    assert length(issues) == 2
    issue = Enum.find(issues, &(&1.id == "42"))
    blocked_issue = Enum.find(issues, &(&1.id == "43"))

    assert issue.id == "42"
    assert issue.state == "ready-for-agent"
    assert issue.native_ref["parent_number"] == 7
    assert issue.native_ref["has_parent"]
    refute issue.native_ref["has_sub_issues"]
    assert issue.blocked_by == []
    assert issue.dispatchable
    refute blocked_issue.dispatchable
    assert blocked_issue.priority_inheritable
    assert blocked_issue.blocked_by == [%{"id" => 1041, "identifier" => "GH-41", "state" => "open"}]
  end

  test "label-state deployments query native closed issues for terminal cleanup" do
    settings = tracker_settings(%{"state_source" => "labels"})

    request_fun = fn "GET", "/repos/octo/repo/issues", params, nil, _settings ->
      assert params["state"] == "closed"
      refute Map.has_key?(params, "labels")
      {:ok, %{status: 200, body: [Map.put(raw_issue(42), "state", "closed"), raw_issue(43)]}}
    end

    assert {:ok, [closed]} = GitHubClient.fetch_issues_by_states_for_test(["closed"], settings, request_fun)
    assert closed.id == "42"
    assert closed.state == "closed"
  end

  test "label-state refresh returns current structure and blocker snapshots" do
    refreshed =
      raw_issue(42)
      |> Map.put("labels", [%{"name" => "In-Progress"}])
      |> Map.put("parent_issue_url", "https://api.github.test/repos/octo/repo/issues/7")

    request_fun = fn
      "GET", "/repos/octo/repo/issues/42", %{}, nil, _settings ->
        {:ok, %{status: 200, body: refreshed}}

      "GET", "/repos/octo/repo/issues/42/parent", %{}, nil, _settings ->
        {:ok, %{status: 200, body: raw_issue(7)}}

      "GET", "/repos/octo/repo/issues/42/sub_issues", %{}, nil, _settings ->
        {:ok, %{status: 200, body: []}}

      "GET", "/repos/octo/repo/issues/42/dependencies/blocked_by", %{"page" => 1, "per_page" => 100}, nil, _settings ->
        {:ok, %{status: 200, body: [Map.put(raw_issue(41), "state", "closed"), raw_issue(40)]}}
    end

    settings = %{
      tracker_settings(%{"state_source" => "labels"})
      | active_states: ["ready-for-agent", "in-progress"],
        terminal_states: ["closed", "ready-for-human", "needs-info", "wontfix"]
    }

    assert {:ok, [issue]} =
             GitHubClient.fetch_issues_by_ids_for_test(["42"], settings, request_fun)

    assert issue.state == "In-Progress"
    assert issue.native_ref["parent_number"] == 7
    assert issue.blocked_by == [%{"id" => 1040, "identifier" => "GH-40", "state" => "open"}]
    refute issue.dispatchable
  end

  test "an in-progress parent with sub-issues is not redispatched" do
    request_fun = fn
      "GET", "/repos/octo/repo/issues", %{"labels" => "in-progress"}, nil, _settings ->
        issue = raw_issue(7) |> Map.put("labels", [%{"name" => "In-Progress"}])
        {:ok, %{status: 200, body: [issue]}}

      "GET", "/repos/octo/repo/issues/7", %{}, nil, _settings ->
        {:ok, %{status: 200, body: Map.put(raw_issue(7), "parent_issue_url", nil)}}

      "GET", "/repos/octo/repo/issues/7/parent", %{}, nil, _settings ->
        {:ok, %{status: 404, body: %{}}}

      "GET", "/repos/octo/repo/issues/7/sub_issues", %{}, nil, _settings ->
        {:ok, %{status: 200, body: [raw_issue(42)]}}

      "GET", "/repos/octo/repo/issues/7/dependencies/blocked_by", %{"page" => 1, "per_page" => 100}, nil, _settings ->
        {:ok, %{status: 200, body: []}}
    end

    settings = %{
      tracker_settings(%{"state_source" => "labels"})
      | active_states: ["in-progress"],
        terminal_states: ["closed", "ready-for-human"]
    }

    assert {:ok, [issue]} =
             GitHubClient.fetch_issues_by_states_for_test(["in-progress"], settings, request_fun)

    refute issue.dispatchable
    refute issue.priority_inheritable
  end

  test "spec scoping fails closed for unrelated active issues" do
    request_fun = fn
      "GET", "/repos/octo/repo/issues", %{"labels" => "ready-for-agent"}, nil, _settings ->
        {:ok, %{status: 200, body: [raw_issue(42)]}}

      "GET", "/repos/octo/repo/issues/42", %{}, nil, _settings ->
        {:ok, %{status: 200, body: Map.put(raw_issue(42), "parent_issue_url", "https://api.github.test/repos/octo/repo/issues/7")}}

      "GET", "/repos/octo/repo/issues/42/parent", %{}, nil, _settings ->
        {:ok, %{status: 200, body: raw_issue(7)}}

      "GET", "/repos/octo/repo/issues/42/sub_issues", %{}, nil, _settings ->
        {:ok, %{status: 200, body: []}}

      "GET", "/repos/octo/repo/issues/42/dependencies/blocked_by", %{"page" => 1, "per_page" => 100}, nil, _settings ->
        {:ok, %{status: 200, body: []}}
    end

    settings = %{
      tracker_settings(%{"state_source" => "labels", "spec_issue_number" => 99})
      | active_states: ["ready-for-agent"],
        terminal_states: ["closed"]
    }

    assert {:ok, [issue]} =
             GitHubClient.fetch_issues_by_states_for_test(
               ["ready-for-agent"],
               settings,
               request_fun
             )

    refute issue.dispatchable
    refute issue.priority_inheritable
  end

  test "label-state polling checks every page of native blockers" do
    request_fun = fn
      "GET", "/repos/octo/repo/issues", %{"labels" => "ready-for-agent"}, nil, _settings ->
        {:ok, %{status: 200, body: [raw_issue(42)]}}

      "GET", "/repos/octo/repo/issues/42", %{}, nil, _settings ->
        {:ok, %{status: 200, body: Map.put(raw_issue(42), "parent_issue_url", nil)}}

      "GET", "/repos/octo/repo/issues/42/parent", %{}, nil, _settings ->
        {:ok, %{status: 404, body: %{}}}

      "GET", "/repos/octo/repo/issues/42/sub_issues", %{}, nil, _settings ->
        {:ok, %{status: 200, body: []}}

      "GET", "/repos/octo/repo/issues/42/dependencies/blocked_by", %{"page" => 1, "per_page" => 100}, nil, _settings ->
        closed_blockers = Enum.map(1000..1099, &(raw_issue(&1) |> Map.put("state", "closed")))
        {:ok, %{status: 200, body: closed_blockers}}

      "GET", "/repos/octo/repo/issues/42/dependencies/blocked_by", %{"page" => 2, "per_page" => 100}, nil, _settings ->
        {:ok, %{status: 200, body: [raw_issue(41)]}}
    end

    settings = %{
      tracker_settings(%{"state_source" => "labels"})
      | active_states: ["ready-for-agent"],
        terminal_states: ["closed"]
    }

    assert {:ok, [issue]} =
             GitHubClient.fetch_issues_by_states_for_test(
               settings.active_states,
               settings,
               request_fun
             )

    refute issue.dispatchable
    assert issue.blocked_by == [%{"id" => 1041, "identifier" => "GH-41", "state" => "open"}]
  end

  test "label-state enrichment runs concurrently, keeps input order, and bounds concurrency" do
    numbers = Enum.to_list(1..20)
    in_flight = :atomics.new(2, [])

    request_fun = fn
      "GET", "/repos/octo/repo/issues", %{"labels" => "ready-for-agent"}, nil, _settings ->
        {:ok, %{status: 200, body: Enum.map(numbers, &raw_issue/1)}}

      "GET", "/repos/octo/repo/issues/" <> rest, _params, nil, _settings ->
        current = :atomics.add_get(in_flight, 1, 1)
        update_max(in_flight, current)
        [number | _] = String.split(rest, "/")
        Process.sleep(rem(String.to_integer(number) * 7, 11))
        :atomics.sub(in_flight, 1, 1)

        if String.ends_with?(rest, "/parent"),
          do: {:ok, %{status: 404, body: %{}}},
          else: {:ok, %{status: 200, body: []}}
    end

    settings = %{
      tracker_settings(%{"state_source" => "labels", "enrichment_concurrency" => 4})
      | active_states: ["ready-for-agent"],
        terminal_states: ["closed"]
    }

    assert {:ok, issues} = GitHubClient.fetch_issues_by_states_for_test(settings.active_states, settings, request_fun)

    expected_order = numbers |> Map.new(&{Integer.to_string(&1), Integer.to_string(&1)}) |> Map.values()
    assert Enum.map(issues, & &1.id) == expected_order
    assert Enum.all?(issues, & &1.dispatchable)
    max_in_flight = :atomics.get(in_flight, 2)
    assert max_in_flight > 1
    assert max_in_flight <= 4
  end

  test "label-state enrichment reports the first failing issue in input order" do
    request_fun = fn
      "GET", "/repos/octo/repo/issues", %{"labels" => "ready-for-agent"}, nil, _settings ->
        {:ok, %{status: 200, body: Enum.map(1..6, &raw_issue/1)}}

      "GET", "/repos/octo/repo/issues/2", %{}, nil, _settings ->
        {:ok, %{status: 200, body: Map.put(raw_issue(2), "parent_issue_url", "https://x/7")}}

      "GET", "/repos/octo/repo/issues/2/parent", _params, nil, _settings ->
        Process.sleep(50)
        {:ok, %{status: 502, body: %{}}}

      "GET", "/repos/octo/repo/issues/5", %{}, nil, _settings ->
        {:ok, %{status: 200, body: Map.put(raw_issue(5), "parent_issue_url", "https://x/7")}}

      "GET", "/repos/octo/repo/issues/5/parent", _params, nil, _settings ->
        {:ok, %{status: 503, body: %{}}}

      "GET", "/repos/octo/repo/issues/" <> rest, _params, nil, _settings ->
        if String.ends_with?(rest, "/parent"),
          do: {:ok, %{status: 404, body: %{}}},
          else: {:ok, %{status: 200, body: []}}
    end

    settings = %{
      tracker_settings(%{"state_source" => "labels"})
      | active_states: ["ready-for-agent"],
        terminal_states: ["closed"]
    }

    assert {:error, {:github_api_status, 502}} =
             GitHubClient.fetch_issues_by_states_for_test(settings.active_states, settings, request_fun)

    assert {:error, :invalid_github_enrichment_concurrency} =
             GitHubClient.validate_settings(tracker_settings(%{"enrichment_concurrency" => 0}))
  end

  test "label-state enrichment skips issues carrying an excluded label" do
    excluded_issue = Map.put(raw_issue(43), "labels", [%{"name" => "ready-for-agent"}, %{"name" => " Blocked-Human "}])

    request_fun = fn
      "GET", "/repos/octo/repo/issues", %{"labels" => "ready-for-agent"}, nil, _settings ->
        {:ok, %{status: 200, body: [raw_issue(42), excluded_issue]}}

      "GET", "/repos/octo/repo/issues/42", %{}, nil, _settings ->
        {:ok, %{status: 200, body: Map.put(raw_issue(42), "parent_issue_url", nil)}}

      "GET", "/repos/octo/repo/issues/42/parent", _params, nil, _settings ->
        {:ok, %{status: 404, body: %{}}}

      "GET", "/repos/octo/repo/issues/42/" <> _rest, _params, nil, _settings ->
        {:ok, %{status: 200, body: []}}
    end

    settings =
      tracker_settings(%{"state_source" => "labels"})
      |> Map.merge(%{active_states: ["ready-for-agent"], terminal_states: ["closed"], excluded_labels: ["blocked-human"]})

    assert {:ok, issues} = GitHubClient.fetch_issues_by_states_for_test(settings.active_states, settings, request_fun)
    assert %{dispatchable: true} = Enum.find(issues, &(&1.id == "42"))
    assert %{dispatchable: false, priority_inheritable: false} = Enum.find(issues, &(&1.id == "43"))
  end

  test "GET requests revalidate with If-None-Match and reuse the cached body on 304" do
    parent = self()
    settings = tracker_settings(%{"token" => "etag-token-#{System.unique_integer([:positive])}"})

    plug = fn conn ->
      if_none_match = Plug.Conn.get_req_header(conn, "if-none-match")
      send(parent, {:github_conditional, conn.method, conn.request_path, conn.query_string, if_none_match})

      case if_none_match do
        [~s(W/"v1")] ->
          Plug.Conn.send_resp(conn, 304, "")

        [] ->
          conn
          |> Plug.Conn.put_resp_header("etag", ~s(W/"v1"))
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!([%{"number" => 1}]))
      end
    end

    path = "/repos/octo/repo/issues/9/sub_issues"
    params = %{"page" => 1, "per_page" => 100}
    get = &GitHubClient.request_for_test("GET", path, &1, nil, settings, plug: plug)

    assert {:ok, %{status: 200, body: [%{"number" => 1}]}} = get.(params)
    assert_received {:github_conditional, "GET", ^path, _query, []}

    assert {:ok, %{status: 200, body: [%{"number" => 1}]}} = get.(params)
    assert_received {:github_conditional, "GET", ^path, _query, [~s(W/"v1")]}

    # Each page is cached independently.
    assert {:ok, %{status: 200}} = get.(%{params | "page" => 2})
    assert_received {:github_conditional, "GET", ^path, query, []}
    assert query =~ "page=2"

    # Non-GET requests are never conditional.
    post_plug = fn conn ->
      send(parent, {:github_conditional, conn.method, conn.request_path, conn.query_string, Plug.Conn.get_req_header(conn, "if-none-match")})
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(201, "{}")
    end

    assert {:ok, %{status: 201}} = GitHubClient.request_for_test("POST", path, %{}, %{"x" => 1}, settings, plug: post_plug)
    assert_received {:github_conditional, "POST", ^path, _query, []}
  end

  test "an exhausted rate limit pauses that endpoint family until reset" do
    parent = self()
    settings = tracker_settings(%{"token" => "limit-token-#{System.unique_integer([:positive])}"})
    reset = System.system_time(:second) + 120

    plug = fn conn ->
      send(parent, {:github_hit, conn.request_path})

      if String.ends_with?(conn.request_path, "/sub_issues") do
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", Integer.to_string(reset))
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, Jason.encode!(%{"message" => "API rate limit exceeded"}))
      else
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, "[]")
      end
    end

    assert {:ok, %{status: 403}} = GitHubClient.request_for_test("GET", "/repos/octo/repo/issues/1/sub_issues", %{}, nil, settings, plug: plug)
    assert_received {:github_hit, "/repos/octo/repo/issues/1/sub_issues"}

    assert {:error, {:github_rate_limited, ^reset}} =
             GitHubClient.request_for_test("GET", "/repos/octo/repo/issues/2/sub_issues", %{}, nil, settings, plug: plug)

    refute_received {:github_hit, _}

    assert {:ok, %{status: 200}} = GitHubClient.request_for_test("GET", "/repos/octo/repo/issues/2/parent", %{}, nil, settings, plug: plug)
    assert_received {:github_hit, "/repos/octo/repo/issues/2/parent"}
  end

  test "http cache degrades to misses when its table is unavailable" do
    key = {:test, System.unique_integer([:positive])}
    assert :ok = HttpCache.store(key, ~s("e"), [1])
    assert HttpCache.lookup(key) == {~s("e"), [1]}
    assert :ok = HttpCache.block(key, 10)
    assert HttpCache.blocked_until(key, 5) == 10
    assert HttpCache.blocked_until(key, 10) == nil

    pid = Process.whereis(HttpCache)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert HttpCache.lookup(key) == nil
    assert HttpCache.store(key, ~s("e"), [1]) == :ok
    assert HttpCache.blocked_until(key, 0) == nil
    assert HttpCache.clear() == :ok

    wait_until(fn -> is_pid(Process.whereis(HttpCache)) and Process.whereis(HttpCache) != pid end)
    assert HttpCache.lookup({:fresh, make_ref()}) == nil
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> wait_again(fun, attempts)
    end
  end

  defp wait_again(fun, attempts) do
    Process.sleep(10)
    wait_until(fun, attempts - 1)
  end

  defp update_max(atomics, current) do
    previous = :atomics.get(atomics, 2)

    if current > previous and :atomics.compare_exchange(atomics, 2, previous, current) != :ok do
      update_max(atomics, current)
    end
  end

  test "github_api preserves REST status and body while rejecting unsafe arguments" do
    test_pid = self()
    tracker_settings = tracker_settings()

    response =
      GitHubAgentTool.execute(
        "github_api",
        %{
          "method" => "post",
          "path" => " /repos/octo/repo/issues/42/comments ",
          "params" => %{"per_page" => 10},
          "body" => %{"body" => "hello"}
        },
        tracker_settings: tracker_settings,
        github_client: fn method, path, params, body, opts ->
          send(test_pid, {:github_tool_called, method, path, params, body, opts})
          {:ok, %{status: 201, body: %{"id" => 9}}}
        end
      )

    assert_received {:github_tool_called, "POST", "/repos/octo/repo/issues/42/comments", %{"per_page" => 10}, %{"body" => "hello"}, [tracker_settings: ^tracker_settings]}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"status" => 201, "body" => %{"id" => 9}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]

    failure =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/repos/octo/repo/issues/404"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: 404, body: %{"message" => "Not Found"}}}
        end
      )

    assert failure["success"] == false

    assert Jason.decode!(failure["output"]) == %{
             "status" => 404,
             "body" => %{"message" => "Not Found"}
           }

    Enum.each(
      [
        %{"method" => "GET", "path" => "https://api.github.com/user"},
        %{"method" => "GET", "path" => "/user", "params" => false},
        %{"path" => "/user"}
      ],
      fn arguments ->
        invalid =
          GitHubAgentTool.execute(
            "github_api",
            arguments,
            github_client: fn _method, _path, _params, _body, _opts ->
              flunk("invalid github_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )
  end

  test "github_api reports unsupported tools, malformed calls, and client failures" do
    unsupported = GitHubAgentTool.execute("not_github_api", %{}, [])
    assert unsupported["success"] == false
    assert Jason.decode!(unsupported["output"])["error"]["supportedTools"] == ["github_api"]

    Enum.each(
      [
        "not-an-object",
        %{"method" => "GET", "path" => 123}
      ],
      fn arguments ->
        invalid =
          GitHubAgentTool.execute(
            "github_api",
            arguments,
            github_client: fn _method, _path, _params, _body, _opts ->
              flunk("malformed github_api arguments should not call the client")
            end
          )

        assert invalid["success"] == false
      end
    )

    malformed_response =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: "not-an-integer", body: %{}}}
        end
      )

    assert malformed_response["success"] == false

    Enum.each(
      [
        :missing_github_token,
        {:github_api_request, :timeout},
        :unexpected_failure
      ],
      fn reason ->
        failure =
          GitHubAgentTool.execute(
            "github_api",
            %{"method" => "GET", "path" => "/user"},
            github_client: fn _method, _path, _params, _body, _opts ->
              {:error, reason}
            end
          )

        assert failure["success"] == false
        assert %{"error" => %{"message" => message}} = Jason.decode!(failure["output"])
        assert is_binary(message)
      end
    )

    non_json_body =
      GitHubAgentTool.execute(
        "github_api",
        %{"method" => "GET", "path" => "/user"},
        github_client: fn _method, _path, _params, _body, _opts ->
          {:ok, %{status: 200, body: self()}}
        end
      )

    assert non_json_body["success"]
    assert non_json_body["output"] =~ "#PID"
  end

  test "tracker binds GitHub tools and token env names from provider config" do
    token_env = "SYMPHONY_GITHUB_TOKEN_#{System.unique_integer([:positive])}"
    previous_token = System.get_env(token_env)
    System.put_env(token_env, "test-token")

    on_exit(fn -> restore_env(token_env, previous_token) end)

    write_github_workflow!(Workflow.workflow_file_path(), "$#{token_env}")

    binding = Tracker.bind_agent_tools()

    assert binding.adapter == GitHubAdapter

    assert binding.secret_environment_names == [
             "GITHUB_TOKEN",
             "GH_TOKEN",
             "GITHUB_ENTERPRISE_TOKEN",
             "GH_ENTERPRISE_TOKEN",
             token_env
           ]

    assert [%{"name" => "github_api"}] = binding.tool_specs
    assert :ok = Config.validate!()
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "github",
      provider:
        Map.merge(
          %{
            "repo" => "octo/repo",
            "token" => "test-token"
          },
          provider_overrides
        ),
      active_states: ["open"],
      terminal_states: ["closed"]
    }
  end

  describe "lean enrichment" do
    defp lean_settings do
      %{
        tracker_settings(%{"state_source" => "labels"})
        | active_states: ["ready-for-agent"],
          terminal_states: ["closed"]
      }
    end

    defp lean_poll(listed, extra) do
      test_pid = self()

      request_fun = fn
        "GET", "/repos/octo/repo/issues", _params, nil, _settings ->
          {:ok, %{status: 200, body: [listed]}}

        "GET", path, params, nil, settings ->
          send(test_pid, {:call, path})

          case extra.(path, params, settings) do
            nil -> {:ok, %{status: 200, body: []}}
            response -> response
          end
      end

      settings = lean_settings()
      {GitHubClient.fetch_issues_by_states_for_test(settings.active_states, settings, request_fun), drain_calls([])}
    end

    defp drain_calls(acc) do
      receive do
        {:call, path} -> drain_calls([path | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp zero_summaries(issue) do
      issue
      |> Map.put("sub_issues_summary", %{"total" => 0, "completed" => 0, "percent_completed" => 0})
      |> Map.put("issue_dependencies_summary", %{
        "blocked_by" => 0,
        "blocking" => 0,
        "total_blocked_by" => 0,
        "total_blocking" => 0
      })
    end

    test "zero summaries skip sub_issues and blocked_by; parent via cacheable issue GET" do
      extra = fn
        "/repos/octo/repo/issues/42", _, _ -> {:ok, %{status: 200, body: Map.put(raw_issue(42), "parent_issue_url", nil)}}
        _, _, _ -> nil
      end

      assert {{:ok, [issue]}, calls} = lean_poll(zero_summaries(raw_issue(42)), extra)
      assert calls == ["/repos/octo/repo/issues/42"]
      refute issue.native_ref["has_parent"]
      refute issue.native_ref["has_sub_issues"]
      refute Map.has_key?(issue.native_ref, "enrich_hints")
      assert issue.blocked_by == []
      assert issue.dispatchable
    end

    test "issue GET with a parent url triggers the parent fetch" do
      extra = fn
        "/repos/octo/repo/issues/42", _, _ ->
          {:ok, %{status: 200, body: Map.put(raw_issue(42), "parent_issue_url", "https://api.github.test/repos/octo/repo/issues/7")}}

        "/repos/octo/repo/issues/42/parent", _, _ ->
          {:ok, %{status: 200, body: raw_issue(7)}}

        _, _, _ ->
          nil
      end

      assert {{:ok, [issue]}, calls} = lean_poll(zero_summaries(raw_issue(42)), extra)
      assert calls == ["/repos/octo/repo/issues/42", "/repos/octo/repo/issues/42/parent"]
      assert issue.native_ref["parent_number"] == 7
    end

    test "parent_issue_url null in the payload makes no parent call and no issue GET" do
      listed = raw_issue(42) |> zero_summaries() |> Map.put("parent_issue_url", nil)
      assert {{:ok, [issue]}, []} = lean_poll(listed, fn _, _, _ -> nil end)
      refute issue.native_ref["has_parent"]
    end

    test "parent_issue_url present in the payload fetches /parent without an issue GET" do
      listed =
        raw_issue(42)
        |> zero_summaries()
        |> Map.put("parent_issue_url", "https://api.github.test/repos/octo/repo/issues/7")

      extra = fn
        "/repos/octo/repo/issues/42/parent", _, _ -> {:ok, %{status: 200, body: raw_issue(7)}}
        _, _, _ -> nil
      end

      assert {{:ok, [issue]}, ["/repos/octo/repo/issues/42/parent"]} = lean_poll(listed, extra)
      assert issue.native_ref["parent_number"] == 7
    end

    test "positive summaries still fetch sub_issues and blockers" do
      listed =
        raw_issue(42)
        |> Map.put("parent_issue_url", nil)
        |> Map.put("sub_issues_summary", %{"total" => 1})
        |> Map.put("issue_dependencies_summary", %{"total_blocked_by" => 1})

      extra = fn
        "/repos/octo/repo/issues/42/sub_issues", _, _ -> {:ok, %{status: 200, body: [raw_issue(44)]}}
        "/repos/octo/repo/issues/42/dependencies/blocked_by", _, _ -> {:ok, %{status: 200, body: [raw_issue(41)]}}
        _, _, _ -> nil
      end

      assert {{:ok, [issue]}, calls} = lean_poll(listed, extra)
      assert "/repos/octo/repo/issues/42/sub_issues" in calls
      assert "/repos/octo/repo/issues/42/dependencies/blocked_by" in calls
      assert issue.native_ref["sub_issue_numbers"] == [44]
      refute issue.dispatchable
    end

    test "missing or malformed summaries fall back to fetching" do
      listed =
        raw_issue(42)
        |> Map.put("parent_issue_url", nil)
        |> Map.put("sub_issues_summary", %{"total" => "0"})

      assert {{:ok, [_]}, calls} = lean_poll(listed, fn _, _, _ -> nil end)

      assert calls == [
               "/repos/octo/repo/issues/42/sub_issues",
               "/repos/octo/repo/issues/42/dependencies/blocked_by"
             ]
    end
  end

  defp raw_issue(number) do
    %{
      "number" => number,
      "id" => 1_000 + number,
      "node_id" => "I_#{number}",
      "title" => "Issue #{number}",
      "body" => "Body #{number}",
      "state" => "open",
      "html_url" => "https://github.test/octo/repo/issues/#{number}",
      "assignee" => %{"login" => "octocat"},
      "labels" => [%{"name" => " Bug "}, %{"name" => "bug"}, %{"name" => "Platform"}],
      "created_at" => "2026-01-01T00:00:00Z",
      "updated_at" => "2026-01-02T00:00:00Z"
    }
  end

  defp write_github_workflow!(path, token) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: github
        provider:
          repo: "octo/repo"
          token: #{Jason.encode!(token)}
        active_states: ["open"]
        terminal_states: ["closed"]
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
