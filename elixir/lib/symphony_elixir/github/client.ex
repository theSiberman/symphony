defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST client for repository issue polling.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.HttpCache
  alias SymphonyElixir.Tracker.Issue

  @default_api_url "https://api.github.com"
  @api_version "2022-11-28"
  @page_size 100
  @user_agent "symphony"
  @default_enrichment_concurrency 8
  @retryable_statuses [408, 500, 502, 503, 504]
  @retryable_transport_reasons [:timeout, :econnrefused, :closed]

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

  @doc false
  @spec request_for_test(String.t(), String.t(), map(), term(), map(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request_for_test(method, path, params, body, tracker_settings, req_options) do
    with {:ok, github_settings} <- settings(tracker_settings) do
      perform_request(method, path, params, body, github_settings, req_options)
    end
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
    {native_states, label_states} = Enum.split_with(state_names, &(&1 == "closed"))

    with {:ok, closed} <- fetch_closed_pages(native_states, settings, request_fun),
         {:ok, labelled} <- fetch_label_state_pages(label_states, settings, request_fun) do
      {:ok, Enum.uniq_by(closed ++ labelled, & &1.id)}
    end
  end

  defp fetch_states_with_settings(_state_names, states, settings, _tracker_settings, request_fun) do
    case github_state_query(states) do
      nil -> {:ok, []}
      query -> do_fetch_pages(settings, query, states, 1, request_fun, [])
    end
  end

  defp fetch_closed_pages([], _settings, _request_fun), do: {:ok, []}

  defp fetch_closed_pages(states, settings, request_fun) do
    do_fetch_pages(settings, "closed", MapSet.new(states), 1, request_fun, [])
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

  # Enrichment costs three sequential GETs per issue, so candidates are
  # enriched concurrently. Results keep input order and the first error (in
  # input order) halts the stream, matching the former sequential semantics.
  defp enrich_and_filter_candidates(issues, settings, request_fun) do
    issues
    |> Task.async_stream(&enrich_candidate(&1, settings, request_fun),
      max_concurrency: settings.enrichment_concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn {:ok, result}, {:ok, acc} ->
      reduce_enriched_candidate(result, acc, settings)
    end)
    |> case do
      {:ok, enriched} -> {:ok, Enum.reverse(enriched)}
      error -> error
    end
  end

  # An issue carrying an excluded label can never be routed or donate
  # priority, so its structure is never consulted; skip its three GETs.
  defp enrich_candidate(%Issue{labels: labels} = issue, %{excluded_labels: [_ | _] = excluded} = settings, request_fun)
       when is_list(labels) do
    if Enum.any?(labels, &(&1 in excluded)) do
      {:ok, %{drop_hints(issue) | dispatchable: false, priority_inheritable: false}}
    else
      enrich_issue(issue, settings, request_fun)
    end
  end

  defp enrich_candidate(issue, settings, request_fun), do: enrich_issue(issue, settings, request_fun)

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

  # Raw-payload hints (from list/refresh payloads) let enrichment skip calls
  # whose answer is already known: zero sub-issues, zero blockers, and the
  # parent link. Missing/malformed hints fall back to fetching.
  defp enrich_hints(issue) do
    hints =
      %{}
      |> put_zero_hint(issue, "sub_issues_summary", "total", "sub_issues_total")
      |> put_zero_hint(issue, "issue_dependencies_summary", "total_blocked_by", "blocked_by_total")

    if Map.has_key?(issue, "parent_issue_url"),
      do: Map.put(hints, "parent_issue_url", issue["parent_issue_url"]),
      else: hints
  end

  defp put_zero_hint(hints, issue, summary_key, field, hint_key) do
    case issue[summary_key] do
      %{^field => total} when is_integer(total) -> Map.put(hints, hint_key, total)
      _ -> hints
    end
  end

  defp attach_hints(native_ref, issue) do
    case enrich_hints(issue) do
      hints when map_size(hints) == 0 -> native_ref
      hints -> Map.put(native_ref || %{}, "enrich_hints", hints)
    end
  end

  defp enrich_issue(%Issue{id: id} = issue, settings, request_fun) do
    base_path = repository_issue_path(settings, String.to_integer(id))
    hints = get_in(issue.native_ref || %{}, ["enrich_hints"]) || %{}
    issue = %{issue | native_ref: Map.delete(issue.native_ref || %{}, "enrich_hints")}

    with {:ok, parent} <- fetch_parent(base_path, hints, settings, request_fun),
         {:ok, sub_issues} <-
           fetch_unless_zero(hints["sub_issues_total"], fn ->
             request_with_settings("GET", base_path <> "/sub_issues", %{}, nil, settings, request_fun, false)
           end),
         {:ok, blockers} <-
           fetch_unless_zero(hints["blocked_by_total"], fn ->
             fetch_list_pages(base_path <> "/dependencies/blocked_by", settings, request_fun, 1, [])
           end) do
      enrich_issue_payload(issue, parent, sub_issues, blockers, settings)
    end
  end

  defp fetch_unless_zero(0, _fun), do: {:ok, []}
  defp fetch_unless_zero(_total, fun), do: fun.()

  defp fetch_parent(base_path, hints, settings, request_fun) do
    case Map.fetch(hints, "parent_issue_url") do
      {:ok, nil} ->
        {:ok, :not_found}

      {:ok, url} when is_binary(url) ->
        request_with_settings("GET", base_path <> "/parent", %{}, nil, settings, request_fun, true)

      _ ->
        # List payloads omit parent_issue_url; the single-issue GET is
        # ETag-cacheable (304 is free), unlike a 404 from /parent.
        with {:ok, payload} <- request_with_settings("GET", base_path, %{}, nil, settings, request_fun, false) do
          case payload do
            %{"parent_issue_url" => url} when is_binary(url) ->
              request_with_settings("GET", base_path <> "/parent", %{}, nil, settings, request_fun, true)

            _ ->
              {:ok, :not_found}
          end
        end
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
      {:ok, drop_hints(issue)}
    end
  end

  defp drop_hints(%Issue{native_ref: %{} = ref} = issue),
    do: %{issue | native_ref: Map.delete(ref, "enrich_hints")}

  defp drop_hints(issue), do: issue

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
        native_ref: issue |> native_ref(repo) |> attach_hints(issue),
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

  defp perform_request(method, path, params, body, settings),
    do: perform_request(method, path, params, body, settings, [])

  defp perform_request(method, path, params, body, settings, req_options) do
    with {:ok, request_method} <- request_method(method),
         :ok <- check_rate_limit(method, path, settings) do
      cache_key = conditional_cache_key(request_method, path, params, settings)
      cached = if cache_key, do: HttpCache.lookup(cache_key)

      request_opts = [
        method: request_method,
        url: settings.api_url <> path,
        headers: github_headers(settings.token) ++ conditional_headers(cached),
        params: params,
        connect_options: [timeout: 30_000],
        retry: &retry_transient?/2
      ]

      request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

      case Req.request(Keyword.merge(request_opts, req_options)) do
        {:ok, response} -> {:ok, handle_response(response, cache_key, cached, method, path, settings)}
        {:error, reason} -> {:error, {:github_api_request, reason}}
      end
    end
  end

  # Only GET is cached. 304 responses do not count against GitHub's primary
  # rate limit, so revalidating with If-None-Match is effectively free. The
  # token is hashed into the key so different credentials never share bodies.
  # Pagination is driven by explicit page params (part of the key) and body
  # length, so caching the decoded body alone is sufficient.
  defp conditional_cache_key(:get, path, params, settings) do
    normalized_params = params |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end) |> Enum.sort()
    {settings.api_url, :erlang.phash2(settings.token), path, normalized_params}
  end

  defp conditional_cache_key(_method, _path, _params, _settings), do: nil

  defp conditional_headers({etag, _body}), do: [{"If-None-Match", etag}]
  defp conditional_headers(nil), do: []

  defp handle_response(%{status: 304}, _cache_key, {_etag, cached_body}, _method, _path, _settings) do
    %{status: 200, body: cached_body}
  end

  defp handle_response(%{status: status} = response, cache_key, _cached, method, path, settings) do
    cond do
      status in 200..299 and cache_key != nil ->
        case Req.Response.get_header(response, "etag") do
          [etag | _] when is_binary(etag) and etag != "" -> HttpCache.store(cache_key, etag, response.body)
          _ -> :ok
        end

      status in [403, 429] ->
        maybe_block_rate_limited(response, method, path, settings)

      true ->
        :ok
    end

    %{status: status, body: response.body}
  end

  # When GitHub reports an exhausted bucket (or a secondary limit with
  # Retry-After), stop calling that endpoint shape until the reset time
  # instead of spending further requests on guaranteed 403/429s.
  defp maybe_block_rate_limited(response, method, path, settings) do
    now = System.system_time(:second)
    remaining = response |> Req.Response.get_header("x-ratelimit-remaining") |> header_integer()
    reset = response |> Req.Response.get_header("x-ratelimit-reset") |> header_integer()
    retry_after = response |> Req.Response.get_header("retry-after") |> header_integer()

    until =
      cond do
        is_integer(retry_after) -> now + retry_after
        remaining == 0 and is_integer(reset) -> reset
        true -> nil
      end

    if is_integer(until) and until > now do
      Logger.warning("GitHub rate limit hit; pausing requests until=#{until} method=#{method} path=#{path}")
      HttpCache.block(rate_limit_scope(path, settings), until)
    end
  end

  defp check_rate_limit(method, path, settings) do
    case HttpCache.blocked_until(rate_limit_scope(path, settings), System.system_time(:second)) do
      nil ->
        :ok

      until ->
        Logger.debug("Skipping rate-limited GitHub request until=#{until} method=#{method} path=#{path}")
        {:error, {:github_rate_limited, until}}
    end
  end

  # Rate-limit buckets differ per endpoint family, so block by endpoint
  # shape (numeric path segments collapsed) rather than globally.
  defp rate_limit_scope(path, settings) do
    {settings.api_url, :erlang.phash2(settings.token), String.replace(path, ~r{/\d+(?=/|$)}, "/:n")}
  end

  defp header_integer([value | _]) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp header_integer(_values), do: nil

  # Req's default retry also retries 429 and sleeps for Retry-After; rate
  # limits are handled above, so only retry genuinely transient failures.
  defp retry_transient?(%Req.Request{method: method}, response_or_exception) when method in [:get, :head] do
    case response_or_exception do
      %Req.Response{status: status} -> status in @retryable_statuses
      %Req.TransportError{reason: reason} -> reason in @retryable_transport_reasons
      %Req.HTTPError{protocol: :http2, reason: :unprocessed} -> true
      _ -> false
    end
  end

  defp retry_transient?(_request, _response_or_exception), do: false

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    api_url = provider["api_url"] || @default_api_url
    repo = resolve_setting(provider["repo"], System.get_env("GITHUB_REPO"))
    token = resolve_setting(provider["token"], System.get_env("GITHUB_TOKEN"))
    spec_issue_number = provider["spec_issue_number"]

    enrichment_concurrency = Map.get(provider, "enrichment_concurrency", @default_enrichment_concurrency)

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

      not valid_enrichment_concurrency?(enrichment_concurrency) ->
        {:error, :invalid_github_enrichment_concurrency}

      true ->
        {:ok,
         %{
           api_url: String.trim_trailing(api_url, "/"),
           repo: repo,
           token: token,
           spec_issue_number: spec_issue_number,
           enrichment_concurrency: enrichment_concurrency,
           excluded_labels: excluded_labels(tracker_settings)
         }}
    end
  end

  defp excluded_labels(%{excluded_labels: labels}) when is_list(labels) do
    for label <- labels, is_binary(label), do: label |> String.trim() |> String.downcase()
  end

  defp excluded_labels(_tracker_settings), do: []

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
  defp valid_enrichment_concurrency?(value), do: is_integer(value) and value > 0
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
