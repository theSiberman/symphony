defmodule SymphonyElixir.GitHub.RunningLabelLedger do
  @moduledoc """
  Durable record of issue ids this scheduler labelled with a shared managed
  running label. The ledger is bound to one `{api_url, repo, label}` scope; a
  ledger for another scope, or one that cannot be decoded, is an error so
  callers fail closed instead of mutating labels they may not own.
  """

  @version 1

  @type scope :: {String.t(), String.t(), String.t()}

  @spec read(Path.t(), scope()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def read(path, scope) do
    case File.read(path) do
      {:ok, contents} -> decode(contents, scope)
      {:error, :enoent} -> {:ok, MapSet.new()}
      {:error, reason} -> {:error, {:running_label_ledger_unreadable, reason}}
    end
  end

  @doc "Atomically replaces the ledger (synced temp file + rename)."
  @spec write(Path.t(), scope(), Enumerable.t()) :: :ok | {:error, term()}
  def write(path, {api_url, repo, label}, ids) do
    temporary = "#{path}.tmp-#{System.unique_integer([:positive])}"

    payload =
      Jason.encode!(%{
        "version" => @version,
        "api_url" => api_url,
        "repo" => repo,
        "label" => label,
        "issue_ids" => ids |> Enum.to_list() |> Enum.sort()
      })

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, payload, [:sync]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, {:running_label_ledger_write_failed, reason}}
    end
  end

  defp decode(contents, {api_url, repo, label}) do
    case Jason.decode(contents) do
      {:ok, %{"version" => @version, "api_url" => ^api_url, "repo" => ^repo, "label" => ^label, "issue_ids" => ids}} when is_list(ids) ->
        if Enum.all?(ids, &valid_id?/1), do: {:ok, MapSet.new(ids)}, else: {:error, :running_label_ledger_corrupt}

      {:ok, %{"version" => @version, "api_url" => _, "repo" => _, "label" => _, "issue_ids" => ids}} when is_list(ids) ->
        {:error, :running_label_ledger_scope_mismatch}

      _ ->
        {:error, :running_label_ledger_corrupt}
    end
  end

  defp valid_id?(id), do: is_binary(id) and id != ""
end
