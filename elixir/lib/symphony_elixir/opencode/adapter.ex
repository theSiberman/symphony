defmodule SymphonyElixir.Opencode.Adapter do
  @moduledoc """
  `SymphonyElixir.AgentRuntime` implementation for a headless opencode server.

  Sessions are directory-scoped (`POST /session?directory=`), so one server hosts
  every ticket workspace rather than one server per worker. A turn is a single
  `POST /session/{id}/message`, which returns the completed assistant message.

  Two capability gaps are declared rather than hidden. opencode enforces
  permissions in-process and has no equivalent of Codex's `writableRoots`, so
  `sandbox_enforcement` is false and containment comes from the worktree plus the
  worker's systemd scope. Turn progress is not streamed here, so the dashboard
  sees a turn's start and end rather than its intermediate tool calls.
  """

  @behaviour SymphonyElixir.AgentRuntime

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Mcp
  alias SymphonyElixir.Opencode.Client
  alias SymphonyElixir.Usage.Payload

  # Errors worth another attempt: the provider or the server was momentarily
  # unavailable, not the candidate or the credentials.
  @transient_errors ["ServiceUnavailableError", "SessionBusyError", "APIError", "UnknownError"]

  @impl true
  def capabilities do
    %{
      structured_usage: true,
      # Reports at turn boundaries only: one synchronous request spans the turn,
      # so there is nothing to emit in between. Silence is not a stall here.
      streams_progress: false,
      rate_limit_reporting: false,
      sandbox_enforcement: false,
      session_resume: true
    }
  end

  @impl true
  def validate_config(settings) do
    opencode = settings.opencode

    cond do
      is_nil(opencode.model) or opencode.model == "" ->
        {:error, {:invalid_workflow_config, "opencode.model is required, as provider/model"}}

      not String.contains?(opencode.model, "/") ->
        {:error, {:invalid_workflow_config, "opencode.model must be provider/model, got: #{opencode.model}"}}

      true ->
        :ok
    end
  end

  @impl true
  def start_session(workspace, opts) do
    settings = Keyword.get_lazy(opts, :settings, fn -> Config.settings!().opencode end)
    base_url = base_url(settings)

    case Client.create_session(base_url, workspace, request_opts(settings, opts)) do
      {:ok, %{"id" => session_id}} ->
        session = %{base_url: base_url, session_id: session_id, workspace: workspace, settings: settings}
        register_tracker_tools(session, opts)
        {:ok, session}

      {:ok, body} ->
        {:error, {:opencode_session_malformed, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def run_turn(session, prompt, _issue, opts) do
    settings = session.settings

    body =
      %{
        "parts" => [%{"type" => "text", "text" => prompt}],
        "model" => model_body(settings.model),
        "agent" => settings.agent
      }
      |> maybe_put("variant", settings.variant)

    request_opts =
      settings
      |> request_opts(opts)
      |> Keyword.put(:receive_timeout, settings.turn_timeout_ms)

    notify(opts, %{
      event: :session_started,
      timestamp: DateTime.utc_now(),
      session_id: session.session_id
    })

    case Client.send_message(session.base_url, session.session_id, body, request_opts) do
      {:ok, message} ->
        # Without this the orchestrator never learns a turn happened: the
        # dashboard shows 0 tokens and no session for a worker that is running
        # normally, which is indistinguishable from one that is hung.
        notify(opts, %{
          event: :turn_completed,
          timestamp: DateTime.utc_now(),
          session_id: session.session_id,
          message: message
        })

        complete_turn(session, message)

      # run_turn sets the receive timeout to the turn budget, so a read timeout
      # here is the turn overrunning that budget, not a flaky connection.
      # Reported as a transport error it classifies transient, and the
      # orchestrator then spends the whole budget again on a turn that will
      # overrun again — GH-263 was on course to burn four hours that way.
      {:error, {:opencode_transport_error, %{reason: :timeout}}} ->
        {:error,
         {:turn_failed,
          %{
            "name" => "TurnBudgetExceeded",
            "data" => %{"turn_timeout_ms" => settings.turn_timeout_ms}
          }}}

      {:error, reason} ->
        {:error, {:response_error, reason}}
    end
  end

  @impl true
  def stop_session(session) do
    case Client.abort(session.base_url, session.session_id, request_opts(session.settings, [])) do
      {:ok, _body} ->
        :ok

      {:error, reason} ->
        # A session that is already finished cannot be aborted; that is not a
        # failure of the run that just completed.
        Logger.debug("opencode session abort returned #{inspect(reason)}")
        :ok
    end
  end

  @impl true
  def classify_failure({kind, detail}) when kind in [:response_error, :turn_failed] do
    if transient_error?(detail), do: :transient, else: :terminal
  end

  def classify_failure(_reason), do: :terminal

  @impl true
  def extract_usage(update) when is_map(update) do
    message = assistant_message(update)

    usage =
      case Map.get(message, "tokens") do
        tokens when is_map(tokens) -> normalize_tokens(tokens, Map.get(message, "cost"))
        _ -> %{}
      end

    # opencode reports no rate-limit buckets; capabilities declares that.
    {usage, nil}
  end

  def extract_usage(_update), do: {%{}, nil}

  # Tracker writes must travel through declared tools rather than a shell, and
  # opencode takes tools over MCP rather than Codex's dynamicTools handshake.
  defp register_tracker_tools(session, opts) do
    case session.settings.mcp_url do
      url when is_binary(url) and url != "" ->
        config = Mcp.Server.remote_config(url)

        registration =
          Client.register_mcp(
            session.base_url,
            Mcp.Server.server_name(),
            config,
            request_opts(session.settings, opts)
          )

        case registration do
          {:ok, _body} ->
            :ok

          {:error, reason} ->
            Logger.warning("opencode tracker tool registration failed: #{inspect(reason)}")
            :ok
        end

      _ ->
        Logger.warning("opencode.mcp_url is unset; this runtime has no tracker tools")
        :ok
    end
  end

  # --- turn completion --------------------------------------------------------

  defp complete_turn(session, message) do
    case Map.get(assistant_message(message), "error") do
      nil ->
        {:ok, %{session_id: session.session_id, message: message}}

      error ->
        {:error, {:turn_failed, error}}
    end
  end

  defp assistant_message(update) do
    cond do
      is_map(Map.get(update, "info")) -> Map.get(update, "info")
      is_map(Map.get(update, :info)) -> Map.get(update, :info)
      is_map(Map.get(update, "message")) -> assistant_message(Map.get(update, "message"))
      is_map(Map.get(update, :message)) -> assistant_message(Map.get(update, :message))
      is_map(update) -> update
      true -> %{}
    end
  end

  # --- failure classification -------------------------------------------------

  defp transient_error?(detail) when is_map(detail) do
    name = Map.get(detail, "name") || Map.get(detail, :name)

    cond do
      name in @transient_errors -> retryable_status?(detail)
      is_map(Map.get(detail, "error")) -> transient_error?(Map.get(detail, "error"))
      true -> false
    end
  end

  defp transient_error?({:opencode_transport_error, _reason}), do: true

  defp transient_error?({:opencode_http_error, status, _body})
       when status == 429 or (status >= 500 and status <= 599),
       do: true

  defp transient_error?(_detail), do: false

  # An APIError carries the upstream status; a client error inside one is the
  # candidate's problem and must not be retried.
  defp retryable_status?(detail) do
    case Payload.get(Map.get(detail, "data") || %{}, ["status", "statusCode", "httpStatusCode"]) do
      nil -> true
      status when status == 429 -> true
      status when status >= 500 and status <= 599 -> true
      _ -> false
    end
  end

  # --- usage ------------------------------------------------------------------

  defp normalize_tokens(tokens, cost) do
    cache = Map.get(tokens, "cache") || %{}

    %{
      "input_tokens" => Payload.get(tokens, "input") || 0,
      "output_tokens" => Payload.get(tokens, "output") || 0,
      "reasoning_tokens" => Payload.get(tokens, "reasoning") || 0,
      "cache_read_tokens" => Payload.get(cache, "read") || 0,
      "cache_write_tokens" => Payload.get(cache, "write") || 0
    }
    |> put_total()
    |> maybe_put("cost_usd", cost)
  end

  defp put_total(usage) do
    Map.put(usage, "total_tokens", usage["input_tokens"] + usage["output_tokens"])
  end

  # --- helpers ----------------------------------------------------------------

  defp model_body(model) do
    case String.split(model, "/", parts: 2) do
      [provider, model_id] -> %{"providerID" => provider, "modelID" => model_id}
      [model_id] -> %{"providerID" => "", "modelID" => model_id}
    end
  end

  defp base_url(%{base_url: base_url}) when is_binary(base_url) and base_url != "",
    do: String.trim_trailing(base_url, "/")

  defp base_url(%{host: host, port: port}), do: "http://#{host}:#{port}"

  defp request_opts(settings, opts) do
    [
      receive_timeout: settings.read_timeout_ms,
      password: System.get_env("OPENCODE_SERVER_PASSWORD"),
      username: System.get_env("OPENCODE_SERVER_USERNAME", "opencode")
    ]
    |> Keyword.merge(Keyword.take(opts, [:request_fun, :receive_timeout]))
  end

  # The orchestrator accepts {:codex_worker_update, issue_id, %{event:, timestamp:}}.
  defp notify(opts, update) do
    case Keyword.get(opts, :on_message) do
      handler when is_function(handler, 1) -> handler.(update)
      _ -> :ok
    end

    :ok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
