defmodule SymphonyElixir.GitHub.RunningLabels do
  @moduledoc """
  Reconciles an explicitly scheduler-owned repository audit label. Enumeration
  finishes before mutations so deleting labels cannot shift pagination.
  """

  alias SymphonyElixir.GitHub.Client

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(settings) do
    label = Map.get(settings, :provider, %{})["managed_running_label"]

    if is_nil(label) or
         (is_binary(label) and String.trim(label) != "" and
            normalize(label) not in reserved_labels(settings)) do
      :ok
    else
      {:error, :invalid_github_managed_running_label}
    end
  end

  @spec bind(map()) :: map() | nil
  def bind(settings) do
    case Map.get(settings, :provider, %{})["managed_running_label"] do
      label when is_binary(label) and label != "" ->
        {api_url, repo} = Client.repository_identity(settings)
        label = String.trim(label)
        provider = Map.merge(settings.provider, %{"api_url" => api_url, "repo" => repo, "managed_running_label" => label})

        %{scope: {api_url, repo, label}, tracker_settings: %{settings | provider: provider}}

      _ ->
        nil
    end
  end

  @spec reconcile(map(), [String.t()], function()) :: :ok | {:error, term()}
  def reconcile(settings, running_ids, request) do
    with :ok <- Client.validate_settings(settings),
         :ok <- validate_config(settings),
         {:ok, labeled} <- fetch_labeled(settings, request, 1, []) do
      running = MapSet.new(running_ids)
      labeled = MapSet.new(labeled)

      removals = Enum.map(MapSet.difference(labeled, running), &{&1, false})
      additions = Enum.map(MapSet.difference(running, labeled), &{&1, true})

      apply_changes(settings, request, removals ++ additions)
    end
  end

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
