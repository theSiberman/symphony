defmodule SymphonyElixir.Codex.ResumeManifest do
  @moduledoc "Validates explicit operator-owned restart evidence without replaying worker environment."
  alias SymphonyElixir.PathSafety
  import Bitwise, only: [band: 2]

  @spec load(Path.t(), String.t() | nil, map()) :: {:ok, map() | nil} | {:error, term()}
  def load(workspace, identifier, settings) do
    case settings.resume_manifest_path do
      nil -> {:ok, nil}
      _path when is_nil(identifier) -> {:error, :resume_identity_required}
      path -> validate(path, workspace, identifier, settings.command)
    end
  end

  defp validate(path, workspace, identifier, command) do
    with true <- is_binary(path) and Path.type(path) == :absolute,
         {:ok, canonical} <- PathSafety.canonicalize(path),
         true <- canonical == Path.expand(path),
         {:ok, workspace_root} <- PathSafety.canonicalize(SymphonyElixir.Config.local_workspace_root()),
         false <- String.starts_with?(Path.dirname(canonical) <> "/", workspace_root <> "/"),
         true <- protected?(Path.dirname(canonical), :directory, 0o700),
         true <- protected?(canonical, :regular, 0o600),
         {:ok, %{type: :regular, size: size}} when size <= 1_048_576 <- File.lstat(canonical),
         {:ok, data} <- File.read(canonical),
         {:ok, %{"schema" => "symphony.codex-resume.v1", "state" => "ready", "entries" => entries}} <- Jason.decode(data),
         true <- is_list(entries) and length(entries) <= 100,
         false <- Enum.any?(entries, &(is_map(&1) and &1["workspace_path"] == workspace and &1["issue_identifier"] != identifier)),
         matching <- Enum.filter(entries, &(is_map(&1) and &1["issue_identifier"] == identifier)) do
      select_entry(matching, workspace, command, canonical, data)
    else
      _ -> {:error, :invalid_resume_manifest}
    end
  end

  defp select_entry([], _workspace, _command, _canonical, _data), do: {:ok, nil}

  defp select_entry([entry], workspace, command, canonical, data) do
    root = Path.join(Path.dirname(canonical), "snapshots")

    with {:ok, validated} <- validate_entry(entry, workspace, command, root),
         {:error, :enoent} <- File.lstat(consumed_path(canonical, validated)) do
      {:ok, validated |> Map.put(:manifest_path, canonical) |> Map.put(:manifest_digest, hash(data))}
    else
      {:ok, _} -> {:error, :resume_already_consumed}
      error -> error
    end
  end

  defp select_entry(_, _, _, _, _), do: {:error, :ambiguous_resume_entry}

  defp validate_entry(entry, workspace, command, root) do
    with %{
           "workspace_path" => ^workspace,
           "thread_id" => thread,
           "profile" => %{"codex_command_sha256" => command_hash, "model" => model, "model_provider" => provider, "reasoning_effort" => effort},
           "history" => history,
           "handoff_text" => handoff,
           "databases" => databases
         } <- entry,
         true <- present?(thread) and present?(model) and present?(provider) and present?(effort),
         true <- valid_handoff?(handoff),
         true <- command_hash == hash(command),
         {:ok, jsonl} <- artifact(history, root, 67_108_864),
         true <- String.ends_with?(jsonl, "\n"),
         lines <- String.split(jsonl, "\n", trim: true),
         {:ok, %{"type" => "session_meta", "payload" => %{"id" => ^thread, "cwd" => ^workspace}}} <- Jason.decode(hd(lines)),
         true <- Enum.all?(lines, &match?({:ok, %{}}, Jason.decode(&1))),
         true <- is_list(databases) and length(databases) == 2,
         true <- Enum.sort(Enum.map(databases, & &1["name"])) == ["state_5.sqlite", "thread_history_1.sqlite"],
         true <- Enum.all?(databases, &valid_database?(&1, root)) do
      {:ok, entry}
    else
      _ -> {:error, :invalid_resume_evidence}
    end
  rescue
    _ -> {:error, :invalid_resume_evidence}
  end

  defp artifact(%{"path" => path, "size" => size, "sha256" => digest}, root, limit)
       when is_binary(path) and is_integer(size) and size > 0 and size <= limit do
    with true <- Path.type(path) == :absolute,
         {:ok, canonical} <- PathSafety.canonicalize(path),
         true <- canonical == Path.expand(path) and String.starts_with?(canonical, root <> "/"),
         true <- protected?(Path.dirname(canonical), :directory, 0o700) and protected?(root, :directory, 0o700),
         true <- protected?(canonical, :regular, 0o600),
         {:ok, %{type: :regular, size: ^size}} <- File.lstat(canonical),
         {:ok, bytes} <- File.read(canonical),
         true <- byte_size(bytes) == size and hash(bytes) == digest do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_resume_artifact}
    end
  end

  defp artifact(_, _, _), do: {:error, :invalid_resume_artifact}

  defp valid_database?(entry, root) do
    case artifact(entry, root, 268_435_456) do
      {:ok, <<"SQLite format 3", 0, _::binary>>} -> true
      _ -> false
    end
  end

  defp present?(value), do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)

  defp valid_handoff?(text) do
    is_binary(text) and byte_size(text) in 1..8_192 and String.valid?(text) and
      String.trim(text) != "" and not String.contains?(text, <<0>>)
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp protected?(path, type, permissions) do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_, uid] <- Regex.run(~r/^Uid:\s+(\d+)/m, status),
         {:ok, info} <- File.lstat(path) do
      info.type == type and info.uid == String.to_integer(uid) and band(info.mode, 0o777) == permissions
    else
      _ -> false
    end
  end

  defp consumed_path(manifest, entry) do
    databases = Enum.map(entry["databases"], &[&1["name"], &1["sha256"]]) |> Enum.sort()
    key = hash(Jason.encode!([entry["issue_identifier"], entry["thread_id"], entry["history"]["sha256"], databases]))
    Path.join([Path.dirname(manifest), "consumed", key <> ".json"])
  end

  @spec consume(map()) :: :ok | {:error, term()}
  def consume(%{manifest_path: manifest} = entry) do
    case load(entry["workspace_path"], entry["issue_identifier"], SymphonyElixir.Config.settings!().codex) do
      {:ok, ^entry} -> publish_consumed(manifest, entry)
      _ -> {:error, :resume_evidence_changed}
    end
  rescue
    _ -> {:error, :resume_consumption_failed}
  end

  defp publish_consumed(manifest, entry) do
    path = consumed_path(manifest, entry)
    directory = Path.dirname(path)
    created = File.mkdir(directory)
    if created == :ok, do: File.chmod(directory, 0o700)

    with true <- created in [:ok, {:error, :eexist}],
         true <- protected?(directory, :directory, 0o700),
         {:ok, file} <- :file.open(String.to_charlist(path), [:write, :exclusive, :raw, :binary]) do
      try do
        :ok = File.chmod(path, 0o600)
        :ok = :file.write(file, Jason.encode!(%{thread_id: entry["thread_id"], consumed_at: DateTime.utc_now()}))
        :ok = :file.sync(file)

        with {:ok, dir} <- :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
          try do
            :file.sync(dir)
          after
            :file.close(dir)
          end
        end
      after
        :file.close(file)
      end
    else
      _ -> {:error, :resume_consumption_failed}
    end
  end
end
