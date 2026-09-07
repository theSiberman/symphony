defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Adapter boundary for the coding agent that executes a ticket.

  Mirrors `SymphonyElixir.Tracker`: a behaviour plus an adapter table keyed on
  `agent.kind`, so the orchestrator never inspects or branches on a vendor's
  payloads. Session lifecycle, failure classification and usage accounting all
  cross this boundary, because each of them was previously expressed in terms of
  Codex's own wire format.

  `SPEC.md` §10 declares the Codex app-server protocol authoritative for the
  upstream project. This boundary is a fork-owned capability and does not change
  that: the Codex adapter still speaks that protocol exactly.
  """

  alias SymphonyElixir.Config

  @adapters %{
    "codex" => SymphonyElixir.Codex.Adapter,
    "opencode" => SymphonyElixir.Opencode.Adapter
  }

  @typedoc "An opaque, adapter-owned handle for a live agent session."
  @type session :: map()

  @typedoc """
  What an adapter supports. The orchestrator degrades against this rather than
  assuming every runtime behaves like Codex.
  """
  @type capabilities :: %{
          structured_usage: boolean(),
          streams_progress: boolean(),
          rate_limit_reporting: boolean(),
          sandbox_enforcement: boolean(),
          session_resume: boolean()
        }

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok
  @callback validate_config(map()) :: :ok | {:error, term()}
  @callback capabilities() :: capabilities()

  @doc """
  Whether a failed run should be retried without spending the abnormal-retry
  budget. Adapters decide this from their own error shape.
  """
  @callback classify_failure(term()) :: :transient | :terminal

  @doc """
  Token usage and rate-limit state carried by one runtime update, as
  `{token_usage, rate_limits}`. Either may be empty or nil when the update
  carries none.
  """
  @callback extract_usage(map()) :: {map(), map() | nil}

  @spec adapter() :: module()
  def adapter do
    {:ok, adapter} = adapter_for_kind(Config.settings!().agent.kind)
    adapter
  end

  @spec adapter_for_kind(String.t()) :: {:ok, module()} | {:error, term()}
  def adapter_for_kind(kind) do
    case Map.fetch(@adapters, kind) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unsupported_agent_runtime_kind, kind}}
    end
  end

  @spec supported_kinds() :: [String.t()]
  def supported_kinds, do: @adapters |> Map.keys() |> Enum.sort()

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []), do: adapter().start_session(workspace, opts)

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []),
    do: adapter().run_turn(session, prompt, issue, opts)

  @spec stop_session(session()) :: :ok
  def stop_session(session), do: adapter().stop_session(session)

  @spec capabilities() :: capabilities()
  def capabilities, do: adapter().capabilities()

  @doc """
  Whether silence between turn start and turn end means the worker is stuck.

  A runtime that streams tool calls and tokens is expected to keep reporting, so
  a gap is evidence of a stall. A runtime that reports only at turn boundaries is
  silent for the whole turn by design, and its liveness bound is the turn budget.
  """
  @spec progress_silence_implies_stall?() :: boolean()
  def progress_silence_implies_stall? do
    Map.get(capabilities(), :streams_progress, true)
  end

  @spec classify_failure(term()) :: :transient | :terminal
  def classify_failure(reason), do: adapter().classify_failure(reason)

  @spec extract_usage(map()) :: {map(), map() | nil}
  def extract_usage(update), do: adapter().extract_usage(update)

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(settings) do
    with {:ok, adapter} <- adapter_for_kind(settings.agent.kind) do
      if function_exported?(adapter, :validate_config, 1),
        do: adapter.validate_config(settings),
        else: :ok
    end
  end
end
