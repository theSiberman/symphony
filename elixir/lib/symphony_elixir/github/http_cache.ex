defmodule SymphonyElixir.GitHub.HttpCache do
  @moduledoc """
  Process-safe store for GitHub conditional-GET validators and rate-limit blocks.

  The named ETS table is owned by this supervised process. Every accessor
  degrades to a cache miss / no-op when the table is absent (owner restarting
  or not started), so callers never fail because of the cache.
  """

  use GenServer

  @table __MODULE__
  @max_entries 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    end

    {:ok, nil}
  end

  @doc "Returns the cached `{etag, body}` for a conditional GET key, or `nil`."
  @spec lookup(term()) :: {String.t(), term()} | nil
  def lookup(key) do
    case safe(fn -> :ets.lookup(@table, {:etag, key}) end, []) do
      [{_key, etag, body}] -> {etag, body}
      _ -> nil
    end
  end

  @doc "Stores a validator and decoded body for a conditional GET key."
  @spec store(term(), String.t(), term()) :: :ok
  def store(key, etag, body) when is_binary(etag) do
    safe(
      fn ->
        if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)
        :ets.insert(@table, {{:etag, key}, etag, body})
      end,
      nil
    )

    :ok
  end

  @doc "Returns the unix time until which `scope` is rate-limited, or `nil`."
  @spec blocked_until(term(), integer()) :: integer() | nil
  def blocked_until(scope, now_unix) do
    case safe(fn -> :ets.lookup(@table, {:rate_limit, scope}) end, []) do
      [{_key, until}] when until > now_unix -> until
      _ -> nil
    end
  end

  @doc "Records that `scope` must not be requested again before `until_unix`."
  @spec block(term(), integer()) :: :ok
  def block(scope, until_unix) when is_integer(until_unix) do
    safe(fn -> :ets.insert(@table, {{:rate_limit, scope}, until_unix}) end, nil)
    :ok
  end

  @doc false
  @spec clear() :: :ok
  def clear do
    safe(fn -> :ets.delete_all_objects(@table) end, nil)
    :ok
  end

  defp safe(fun, fallback) do
    fun.()
  rescue
    ArgumentError -> fallback
  end
end
