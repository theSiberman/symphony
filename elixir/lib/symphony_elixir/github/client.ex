defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST client for repository issue polling.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @default_api_url "https://api.github.com"
  @api_version "2022-11-28"
  @page_size 100
  @user_agent "symphony"

  @doc "Resolves repository identity for scheduler-owned mutation bindings."
  @spec repository_identity(map()) :: {String.t() | nil, String.t() | nil}
  def repository_identity(tracker_settings) do
    provider = provider_settings(tracker_settings)
    {provider["api_url"] || @default_api_url, resolve_setting(provider["repo"], System.get_env("GITHUB_REPO"))}
  end

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    [
      "GITHUB_TOKEN",
      "GH_TOKEN",
      "GITHUB_ENTERPRISE_TOKEN",
      "GH_ENTERPRISE_TOKEN" | env_reference_names([provider["token"]])
    ]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_issues_by_states(state_names, Config.settings!().tracker, &perform_request/5)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_issues_by_ids(issue_ids, Config.settings!().tracker, &perform_request/5)
  end

  @spec request(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request(method, path, params, body, opts \\ [])
      when is_binary(method) and is_binary(path) and is_map(params) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_request/5)

    with {:ok, github_settings} <- settings(tracker_settings) do
      request_fun.(method, path, params, body, github_settings)
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, repo) when is_map(issue) and is_binary(repo) do
    normalize_issue(issue, repo)
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(state_names, tracker_settings, request_fun)
      when is_list(state_names) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_states(state_names, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, tracker_settings, request_fun)
      when is_list(issue_ids) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_ids(issue_ids, tracker_settings, request_fun)
  end

  defp fetch_issues_by_states(state_names, tracker_settings, request_fun) do
    normalized_state_names = state_names |> Enum.map(&normalize_state/1) |> Enum.uniq()
    normalized_states = MapSet.new(normalized_state_names)

    with {:ok, github_settings} <- settings(tracker_settings) do
      fetch_states_with_settings(
        normalized_state_names,
        normalized_states,
        github_settings,
        tracker_settings,
        request_fun
      )
    end
  end

  defp fetch_states_with_settings(
         state_names,
         _states,
         settings,
         %{provider: %{"state_source" => "labels"}},
         request_fun
       ) do
    fetch_label_state_pages(state_names, settings, request_fun)
  end

  defp fetch_states_with_settings(_state_names, states, settings, _tracker_settings, request_fun) do
    case github_state_query(states) do
      nil -> {:ok, []}
      query -> do_fetch_pages(settings, query, states, 1, request_fun, [])
    end
  end

  defp fetch_label_state_pages(states, settings, request_fun) do
    Enum.reduce_while(states, {:ok, %{}}, fn state, {:ok, issues_by_id} ->
      case do_fetch_label_pages(settings, state, 1, request_fun, []) do
        {:ok, issues} ->
          merged = Enum.reduce(issues, issues_by_id, &Map.put_new(&2, &1.id, &1))
          {:cont, {:ok, merged}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues_by_id} -> enrich_and_filter_candidates(Map.values(issues_by_id), settings, request_fun)
      error -> error
    end
  end

  defp do_fetch_label_pages(settings, label, page, request_fun, acc) do
    params = %{
      "state" => "open",
      "labels" => label,
      "per_page" => @page_size,
      "page" => page,
      "sort" => "created",
      "direction" => "asc"
    }

    with {:ok, payload} <-
           request_with_settings(
             "GET",
             repository_issues_path(settings),
             params,
             nil,
             settings,
             request_fun,
             false
           ) do
      issues =
        payload
        |> Enum.map(&normalize_issue(&1, settings.repo, matching_label(&1, label) || label))
        |> Enum.reject(&is_nil/1)

      updated_acc = [issues | acc]

      if length(payload) < @page_size do
        {:ok, updated_acc |> Enum.reverse() |> List.flatten()}
      else
        do_fetch_label_pages(settings, label, page + 1, request_fun, updated_acc)
      end
    end
  end

  defp enrich_and_filter_candidates(issues, settings, request_fun) do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      issue
      |> enrich_issue(settings, request_fun)
      |> reduce_enriched_candidate(acc, settings)
    end)
    |> case do
      {:ok, enriched} -> {:ok, Enum.reverse(enriched)}
      error -> error
    end
  end

  defp reduce_enriched_candidate({:ok, %Issue{} = issue}, acc, _settings),
    do: {:cont, {:ok, [issue | acc]}}

  defp reduce_enriched_candidate({:error, reason}, _acc, _settings), do: {:halt, {:error, reason}}

  defp dispatch_candidate?(issue, %{spec_issue_number: scope})
       when is_integer(scope) and scope >= 0 do
    in_spec_scope?(issue, scope) and resumable_candidate?(issue)
  end

  defp dispatch_candidate?(issue, _settings), do: resumable_candidate?(issue)

  defp in_spec_scope?(_issue, 0), do: false

  defp in_spec_scope?(%Issue{id: id, native_ref: native_ref}, scope) do
    id == Integer.to_string(scope) or Map.get(native_ref, "parent_number") == scope
  end

  defp resumable_candidate?(%Issue{state: state, native_ref: native_ref}) when is_map(native_ref) do
    normalize_state(state) != "in-progress" or native_ref["has_sub_issues"] != true
  end

  defp resumable_candidate?(%Issue{}), do: true

  defp enrich_issue(%Issue{id: id} = issue, settings, request_fun) do
    base_path = repository_issue_path(settings, String.to_integer(id))

    with {:ok, parent} <-
           request_with_settings("GET", base_path <> "/parent", %{}, nil, settings, request_fun, true),
         {:ok, sub_issues} <-
           request_with_settings("GET", base_path <> "/sub_issues", %{}, nil, settings, request_fun, false),
         {:ok, blockers} <-
           fetch_list_pages(
             base_path <> "/dependencies/blocked_by",
             settings,
             request_fun,
             1,
             []
           ) do
      enrich_issue_payload(issue, parent, sub_issues, blockers, settings)
    end
  end

  defp enrich_issue_payload(issue, parent, sub_issues, blockers, settings) do
    parent_number = if is_map(parent), do: parent["number"], else: nil
    sub_issue_numbers = Enum.flat_map(sub_issues, &positive_issue_number/1)

    native_ref =
      (issue.native_ref || %{})
      |> Map.put("has_parent", is_integer(parent_number))
      |> Map.put("parent_number", parent_number)
      |> Map.put("has_sub_issues", sub_issue_numbers != [])
      |> Map.put("sub_issue_numbers", sub_issue_numbers)

    normalized_blockers =
      blockers
      |> Enum.filter(&(&1["state"] != "closed"))
      |> Enum.map(fn blocker ->
        %{
          "id" => blocker["id"],
          "identifier" => if(is_integer(blocker["number"]), do: "GH-#{blocker["number"]}"),
          "state" => blocker["state"]
        }
      end)

    enriched = %{issue | native_ref: native_ref, blocked_by: normalized_blockers}
    priority_inheritable = enriched.dispatchable and dispatch_candidate?(enriched, settings)

    {:ok,
     %{
       enriched
       | priority_inheritable: priority_inheritable,
         dispatchable: priority_inheritable and normalized_blockers == []
     }}
  end

  defp fetch_list_pages(path, settings, request_fun, page, acc) do
    params = %{"per_page" => @page_size, "page" => page}

    with {:ok, payload} <-
           request_with_settings("GET", path, params, nil, settings, request_fun, false) do
      updated_acc = [payload | acc]

      if length(payload) < @page_size do
        {:ok, updated_acc |> Enum.reverse() |> List.flatten()}
      else
        fetch_list_pages(path, settings, request_fun, page + 1, updated_acc)
      end
    end
  end

  defp positive_issue_number(%{"number" => number}) when is_integer(number) and number > 0, do: [number]
  defp positive_issue_number(_issue), do: []

  defp fetch_issues_by_ids(issue_ids, tracker_settings, request_fun) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, github_settings} <- settings(tracker_settings) do
          fetch_issue_ids(ids, github_settings, tracker_settings, request_fun, [])
        end
    end
  end

  defp do_fetch_pages(settings, state_query, requested_states, page, request_fun, acc) do
    params = %{
      "state" => state_query,
      "per_page" => @page_size,
      "page" => page,
      "sort" => "created",
      "direction" => "asc"
    }

    with {:ok, payload} <-
           request_with_settings(
             "GET",
             repository_issues_path(settings),
             params,
             nil,
             settings,
             request_fun,
             false
           ) do
      issues = normalize_state_page(payload, settings.repo, requested_states)
      updated_acc = [issues | acc]

      if length(payload) < @page_size do
        {:ok, updated_acc |> Enum.reverse() |> List.flatten()}
      else
        do_fetch_pages(settings, state_query, requested_states, page + 1, request_fun, updated_acc)
      end
    end
  end

  defp fetch_issue_ids([], _settings, _tracker_settings, _request_fun, acc),
    do: {:ok, Enum.reverse(acc)}

  defp fetch_issue_ids([id | rest], settings, tracker_settings, request_fun, acc) do
    with {:ok, issue_number} <- parse_issue_number(id),
         {:ok, payload} <-
           request_with_settings(
             "GET",
             repository_issue_path(settings, issue_number),
             %{},
             nil,
             settings,
             request_fun,
             true
           ) do
      continue_issue_id_fetch(payload, rest, settings, tracker_settings, request_fun, acc)
    end
  end

  defp continue_issue_id_fetch(:not_found, rest, settings, tracker_settings, request_fun, acc) do
    fetch_issue_ids(rest, settings, tracker_settings, request_fun, acc)
  end

  defp continue_issue_id_fetch(
         %{} = raw_issue,
         rest,
         settings,
         tracker_settings,
         request_fun,
         acc
       ) do
    state_override = issue_state(raw_issue, tracker_settings)

    case normalize_issue(raw_issue, settings.repo, state_override) do
      %Issue{} = issue ->
        with {:ok, issue} <- maybe_enrich_refresh(issue, settings, tracker_settings, request_fun) do
          fetch_issue_ids(rest, settings, tracker_settings, request_fun, [issue | acc])
        end

      nil ->
        {:error, :github_unknown_payload}
    end
  end

  defp continue_issue_id_fetch(
         _payload,
         _rest,
         _settings,
         _tracker_settings,
         _request_fun,
         _acc
       ) do
    {:error, :github_unknown_payload}
  end

  defp maybe_enrich_refresh(issue, settings, tracker_settings, request_fun) do
    if label_states?(tracker_settings) do
      enrich_issue(issue, settings, request_fun)
    else
      {:ok, issue}
    end
  end

  defp issue_state(%{"state" => "closed"}, _tracker_settings), do: "closed"

  defp issue_state(raw_issue, tracker_settings) do
    if label_states?(tracker_settings) do
      (tracker_settings.active_states ++ tracker_settings.terminal_states)
      |> Enum.reject(&(normalize_state(&1) == "closed"))
      |> Enum.find_value(&matching_label(raw_issue, &1))
    end
  end

  defp matching_label(raw_issue, expected_label) do
    Enum.find(provider_labels(raw_issue), &(normalize_state(&1) == normalize_state(expected_label)))
  end

  defp normalize_state_page(payload, repo, requested_states) do
    issues = Enum.map(payload, &normalize_issue(&1, repo))
    malformed_count = Enum.count(issues, &is_nil/1)

    if malformed_count > 0 do
      Logger.warning("Dropping malformed GitHub issue records count=#{malformed_count}")
    end

    issues
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&MapSet.member?(requested_states, normalize_state(&1.state)))
  end

  defp normalize_issue(issue, repo, state_override \\ nil)

  defp normalize_issue(issue, repo, state_override) when is_map(issue) and is_binary(repo) do
    issue_number = issue["number"]
    state = state_override || issue["state"]

    if is_integer(issue_number) and issue_number > 0 and
         Enum.all?([issue["title"], state], &present_string?/1) do
      %Issue{
        id: Integer.to_string(issue_number),
        native_ref: native_ref(issue, repo),
        identifier: "GH-#{issue_number}",
        title: issue["title"],
        description: issue["body"],
        state: state,
        url: issue["html_url"],
        assignee_id: get_in(issue, ["assignee", "login"]),
        labels: extract_labels(issue),
        blocked_by: [],
        dispatchable: not Map.has_key?(issue, "pull_request"),
        created_at: parse_datetime(issue["created_at"]),
        updated_at: parse_datetime(issue["updated_at"])
      }
    end
  end

  defp normalize_issue(_issue, _repo, _state_override), do: nil

  defp native_ref(issue, repo) do
    %{
      "id" => issue["id"],
      "node_id" => issue["node_id"],
      "number" => issue["number"],
      "repo" => repo
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      empty when map_size(empty) == 0 -> nil
      ref -> ref
    end
  end

  defp provider_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp provider_labels(_issue), do: []

  defp extract_labels(issue) do
    issue
    |> provider_labels()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp request_with_settings(method, path, params, body, settings, request_fun, allow_not_found) do
    case request_fun.(method, path, params, body, settings) do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        {:ok, payload}

      {:ok, %{status: 404}} when allow_not_found ->
        {:ok, :not_found}

      {:ok, %{status: status}} when is_integer(status) ->
        Logger.error("GitHub API request failed status=#{status} method=#{method} path=#{path}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :github_unknown_payload}
    end
  end

  defp perform_request(method, path, params, body, settings) do
    with {:ok, request_method} <- request_method(method) do
      request_opts = [
        method: request_method,
        url: settings.api_url <> path,
        headers: github_headers(settings.token),
        params: params,
        connect_options: [timeout: 30_000]
      ]

      request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

      case Req.request(request_opts) do
        {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
        {:error, reason} -> {:error, {:github_api_request, reason}}
      end
    end
  end

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    api_url = provider["api_url"] || @default_api_url
    repo = resolve_setting(provider["repo"], System.get_env("GITHUB_REPO"))
    token = resolve_setting(provider["token"], System.get_env("GITHUB_TOKEN"))
    spec_issue_number = provider["spec_issue_number"]

    cond do
      not valid_api_url?(api_url) ->
        {:error, :invalid_github_api_url}

      not present_string?(repo) ->
        {:error, :missing_github_repo}

      not valid_repo?(repo) ->
        {:error, :invalid_github_repo}

      not present_string?(token) ->
        {:error, :missing_github_token}

      not valid_spec_issue_number?(spec_issue_number) ->
        {:error, :invalid_github_spec_issue_number}

      true ->
        {:ok,
         %{
           api_url: String.trim_trailing(api_url, "/"),
           repo: repo,
           token: token,
           spec_issue_number: spec_issue_number
         }}
    end
  end

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp resolve_setting(nil, fallback), do: normalize_string(fallback)

  defp resolve_setting("$" <> env_name, fallback) do
    if valid_env_name?(env_name) do
      normalize_string(System.get_env(env_name) || fallback)
    else
      nil
    end
  end

  defp resolve_setting(value, _fallback), do: normalize_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> env_name when is_binary(env_name) -> if valid_env_name?(env_name), do: [env_name], else: []
      _ -> []
    end)
  end

  defp valid_env_name?(name), do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_api_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) -> true
      _ -> false
    end
  end

  defp valid_api_url?(_value), do: false
  defp valid_spec_issue_number?(nil), do: true
  defp valid_spec_issue_number?(value), do: is_integer(value) and value >= 0
  defp valid_repo?(repo) when is_binary(repo), do: String.match?(repo, ~r/^[^\s\/]+\/[^\s\/]+$/)
  defp valid_repo?(_repo), do: false

  defp repository_issues_path(settings), do: "/repos/#{encoded_repo(settings.repo)}/issues"

  defp repository_issue_path(settings, issue_number),
    do: "#{repository_issues_path(settings)}/#{issue_number}"

  defp encoded_repo(repo) do
    repo
    |> String.split("/", parts: 2)
    |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  defp github_headers(token) do
    [
      {"Accept", "application/vnd.github+json"},
      {"Authorization", "Bearer #{token}"},
      {"X-GitHub-Api-Version", @api_version},
      {"User-Agent", @user_agent}
    ]
  end

  defp github_state_query(states) do
    has_open? = MapSet.member?(states, "open")
    has_closed? = MapSet.member?(states, "closed")

    cond do
      has_open? and has_closed? -> "all"
      has_open? -> "open"
      has_closed? -> "closed"
      true -> nil
    end
  end

  defp label_states?(tracker_settings),
    do: provider_settings(tracker_settings)["state_source"] == "labels"

  defp parse_issue_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_github_issue_id}
    end
  end

  defp parse_issue_number(_value), do: {:error, :invalid_github_issue_id}

  defp request_method("GET"), do: {:ok, :get}
  defp request_method("POST"), do: {:ok, :post}
  defp request_method("PATCH"), do: {:ok, :patch}
  defp request_method("PUT"), do: {:ok, :put}
  defp request_method("DELETE"), do: {:ok, :delete}
  defp request_method(_method), do: {:error, :invalid_github_method}

  defp normalize_state(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_state(_value), do: ""

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false
end
