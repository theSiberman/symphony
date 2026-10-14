defmodule SymphonyElixir.GitHub.RunningLabels do
  @moduledoc """
  Reconciles a scheduler-managed repository audit label. Enumeration finishes
  before mutations so deleting labels cannot shift pagination.

  Ownership is `"exclusive"` by default: every labelled issue that is not
  running here is unlabelled. With `"ledger"` ownership the label is shared
  with other actors (for example a human operator); only issues recorded in a
  durable ledger of ids this scheduler labelled are ever unlabelled, and
  labelled issues outside the ledger are foreign claims that must not be
  dispatched.
  """

  alias SymphonyElixir.GitHub.{Client, RunningLabelLedger}

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(settings) do
    provider = Map.get(settings, :provider, %{})
    label = provider["managed_running_label"]

    if is_nil(label) or
         (is_binary(label) and String.trim(label) != "" and
            normalize(label) not in reserved_labels(settings)) do
      validate_ownership(provider, label)
    else
      {:error, :invalid_github_managed_running_label}
    end
  end

  defp validate_ownership(provider, label) do
    case provider["managed_running_label_ownership"] do
      ownership when ownership in [nil, "exclusive"] ->
        :ok

      "ledger" when is_binary(label) ->
        if absolute_path?(provider["managed_running_label_ledger_path"]),
          do: :ok,
          else: {:error, :invalid_github_managed_running_label_ledger_path}

      _ ->
        {:error, :invalid_github_managed_running_label_ownership}
    end
  end

  @doc """
  Returns the dispatch guard for ledger ownership: `nil` when the label is not
  shared, `{:ok, label, owned_ids}` when it is, or an error when the ledger
  cannot be trusted (callers must then fail closed).
  """
  @spec guard(map()) :: nil | {:ok, String.t(), MapSet.t(String.t())} | {:error, term()}
  def guard(settings) do
    case ledger(settings) do
      nil ->
        nil

      {path, {_api_url, _repo, label} = scope} ->
        with {:ok, ids} <- RunningLabelLedger.read(path, scope), do: {:ok, label, ids}
    end
  end

  @spec bind(map()) :: map() | nil
  def bind(settings) do
    case Map.get(settings, :provider, %{})["managed_running_label"] do
      label when is_binary(label) and label != "" ->
        {api_url, repo} = Client.repository_identity(settings)
        label = String.trim(label)
        provider = Map.merge(settings.provider, %{"api_url" => api_url, "repo" => repo, "managed_running_label" => label})
        settings = %{settings | provider: provider}
        ownership = if ledger = ledger(settings), do: {:ledger, elem(ledger, 0)}, else: :exclusive

        %{scope: {api_url, repo, label}, ownership: ownership, tracker_settings: settings}

      _ ->
        nil
    end
  end

  @spec reconcile(map(), [String.t()], function()) :: :ok | {:error, term()}
  def reconcile(settings, running_ids, request) do
    with :ok <- Client.validate_settings(settings),
         :ok <- validate_config(settings),
         {:ok, owned} <- read_ledger(settings),
         {:ok, labeled} <- fetch_labeled(settings, request, 1, []) do
      running = MapSet.new(running_ids)
      labeled = MapSet.new(labeled)

      if owned do
        reconcile_ledger(settings, request, running, labeled, owned)
      else
        removals = Enum.map(MapSet.difference(labeled, running), &{&1, false})
        additions = Enum.map(MapSet.difference(running, labeled), &{&1, true})

        apply_changes(settings, request, removals ++ additions)
      end
    end
  end

  # Shared label: only ever unlabel ids this scheduler recorded. Additions are
  # recorded before the POST so a crash cannot leave an unrecorded own label.
  defp reconcile_ledger(settings, request, running, labeled, owned) do
    {path, scope} = ledger(settings)
    additions = MapSet.difference(running, labeled)
    removals = owned |> MapSet.intersection(labeled) |> MapSet.difference(running)
    stale = owned |> MapSet.difference(labeled) |> MapSet.difference(running)
    recorded = MapSet.union(owned, additions)

    with :ok <- write_ledger(path, scope, owned, recorded) do
      {released, removal_result} = release_owned(settings, request, removals)
      addition_result = apply_changes(settings, request, Enum.map(additions, &{&1, true}))
      remaining = recorded |> MapSet.difference(stale) |> MapSet.difference(released)
      write_result = write_ledger(path, scope, recorded, remaining)

      removal_result |> first_error(addition_result) |> first_error(write_result)
    end
  end

  # A 404 means the label (or issue) is already gone, so the id is released too.
  defp release_owned(settings, request, removals) do
    Enum.reduce(removals, {MapSet.new(), :ok}, fn id, {released, result} ->
      case set_label(settings, request, id, false) do
        :ok -> {MapSet.put(released, id), result}
        {:error, {:running_label_http_status, 404}} -> {MapSet.put(released, id), result}
        error -> {released, first_error(result, error)}
      end
    end)
  end

  defp first_error(:ok, result), do: result
  defp first_error(error, _result), do: error

  defp write_ledger(_path, _scope, ids, ids), do: :ok
  defp write_ledger(path, scope, _previous, ids), do: RunningLabelLedger.write(path, scope, ids)

  defp read_ledger(settings) do
    case ledger(settings) do
      nil -> {:ok, nil}
      {path, scope} -> RunningLabelLedger.read(path, scope)
    end
  end

  defp ledger(settings) do
    provider = settings.provider

    if provider["managed_running_label_ownership"] == "ledger" do
      {api_url, repo} = Client.repository_identity(settings)
      {provider["managed_running_label_ledger_path"], {api_url, repo, String.trim(provider["managed_running_label"])}}
    end
  end

  defp absolute_path?(path), do: is_binary(path) and Path.type(path) == :absolute

  defp apply_changes(settings, request, changes) do
    Enum.reduce(changes, :ok, fn {id, present}, result ->
      case set_label(settings, request, id, present) do
        :ok -> result
        error -> error
      end
    end)
  end

  defp fetch_labeled(settings, request, page, acc) do
    params = %{"state" => "all", "labels" => settings.provider["managed_running_label"], "per_page" => 100, "page" => page}

    case request.("GET", issues_path(settings), params, nil, tracker_settings: settings) do
      {:ok, %{status: 200, body: items}} when is_list(items) ->
        collect_page(settings, request, page, acc, items)

      result ->
        request_error(result)
    end
  end

  defp collect_page(settings, request, page, acc, items) do
    if Enum.all?(items, &valid_item?/1) do
      ids = for %{"number" => number} = item <- items, not Map.has_key?(item, "pull_request"), do: Integer.to_string(number)
      acc = [ids | acc]

      if length(items) == 100 do
        fetch_labeled(settings, request, page + 1, acc)
      else
        {:ok, List.flatten(acc)}
      end
    else
      {:error, :invalid_running_label_payload}
    end
  end

  defp valid_item?(%{"number" => number}), do: is_integer(number) and number > 0
  defp valid_item?(_item), do: false

  defp set_label(settings, request, id, present) do
    label = settings.provider["managed_running_label"]
    path = "#{issues_path(settings)}/#{URI.encode(id, &URI.char_unreserved?/1)}/labels"

    result =
      if present do
        request.("POST", path, %{}, %{"labels" => [label]}, tracker_settings: settings)
      else
        request.("DELETE", "#{path}/#{URI.encode(label, &URI.char_unreserved?/1)}", %{}, nil, tracker_settings: settings)
      end

    case result do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      result -> request_error(result)
    end
  end

  defp request_error({:ok, %{status: status}}), do: {:error, {:running_label_http_status, status}}
  defp request_error({:error, _reason}), do: {:error, :running_label_request_failed}
  defp request_error(_result), do: {:error, :invalid_running_label_response}

  defp issues_path(settings) do
    repo = settings.provider["repo"] |> String.split("/") |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
    "/repos/#{repo}/issues"
  end

  defp reserved_labels(settings) do
    states =
      if settings.provider["state_source"] == "labels" do
        Map.get(settings, :active_states, []) ++ Map.get(settings, :terminal_states, [])
      else
        []
      end

    (Map.get(settings, :required_labels, []) ++ states)
    |> Enum.map(&normalize/1)
  end

  defp normalize(value), do: value |> String.trim() |> String.downcase()
end
