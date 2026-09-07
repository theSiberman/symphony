defmodule SymphonyElixir.Codex.Adapter do
  @moduledoc """
  `SymphonyElixir.AgentRuntime` implementation for the Codex app-server.

  Session lifecycle delegates to `SymphonyElixir.Codex.AppServer`, which owns the
  JSON-RPC transport. The failure and usage knowledge here previously lived in
  `SymphonyElixir.Orchestrator`, which had to match the literal `codexErrorInfo`
  key and read Codex-internal token paths such as
  `params.msg.payload.info.total_token_usage` to do its job. That is vendor wire
  format, so it belongs behind the adapter boundary.
  """

  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Usage.Payload

  @transient_error_codes ["rateLimitExceeded", "serverOverloaded", "internalServerError"]

  @absolute_token_paths [
    ["params", "msg", "payload", "info", "total_token_usage"],
    [:params, :msg, :payload, :info, :total_token_usage],
    ["params", "msg", "info", "total_token_usage"],
    [:params, :msg, :info, :total_token_usage],
    ["params", "tokenUsage", "total"],
    [:params, :tokenUsage, :total],
    ["tokenUsage", "total"],
    [:tokenUsage, :total]
  ]

  @impl true
  def start_session(workspace, opts), do: AppServer.start_session(workspace, opts)

  @impl true
  def run_turn(session, prompt, issue, opts), do: AppServer.run_turn(session, prompt, issue, opts)

  @impl true
  def stop_session(session), do: AppServer.stop_session(session)

  @impl true
  def validate_config(_settings), do: :ok

  @impl true
  def capabilities do
    %{
      structured_usage: true,
      rate_limit_reporting: true,
      sandbox_enforcement: true,
      session_resume: true
    }
  end

  @impl true
  def classify_failure({kind, detail}) when kind in [:response_error, :turn_failed] do
    if transient_provider_error?(detail), do: :transient, else: :terminal
  end

  def classify_failure(_reason), do: :terminal

  @impl true
  def extract_usage(update) when is_map(update) do
    {extract_token_usage(update), extract_rate_limits(update)}
  end

  def extract_usage(_update), do: {%{}, nil}

  # --- failure classification -------------------------------------------------

  defp transient_provider_error?(%{"codexErrorInfo" => info}) do
    case info do
      code when code in @transient_error_codes -> true
      %{"httpConnectionFailed" => detail} -> transient_http_error?(detail)
      %{"responseStreamConnectionFailed" => detail} -> transient_http_error?(detail)
      %{"responseStreamDisconnected" => detail} -> transient_http_error?(detail)
      %{"responseTooManyFailedAttempts" => detail} -> transient_http_error?(detail)
      _ -> false
    end
  end

  defp transient_provider_error?(%{"error" => error}), do: transient_provider_error?(error)
  defp transient_provider_error?(%{"data" => data}), do: transient_provider_error?(data)
  defp transient_provider_error?(%{"turn" => turn}), do: transient_provider_error?(turn)
  defp transient_provider_error?(_detail), do: false

  defp transient_http_error?(%{"httpStatusCode" => status}),
    do: is_nil(status) or status == 429 or (is_integer(status) and status >= 500 and status <= 599)

  defp transient_http_error?(_detail), do: false

  # --- usage accounting -------------------------------------------------------

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload),
    do: Payload.explicit_map_at_paths(payload, @absolute_token_paths)

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          Payload.map_at_path(payload, ["params", "usage"]) ||
          Payload.map_at_path(payload, [:params, :usage])

      if is_map(direct) and Payload.integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) -> direct
      rate_limits_map?(payload) -> payload
      true -> rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload), do: rate_limit_payloads(payload)
  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    payload |> Map.values() |> first_rate_limits()
  end

  defp rate_limit_payloads(payload) when is_list(payload), do: first_rate_limits(payload)

  defp first_rate_limits(values) do
    Enum.reduce_while(values, nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") || Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") || Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false
end
