defmodule SymphonyElixir.Usage.Payload do
  @moduledoc """
  Pure helpers for reading numbers out of agent runtime payloads.

  Shared by the orchestrator's usage accounting and by runtime adapters that
  parse their vendor's wire format. Extracted so the two never drift: the
  orchestrator interprets an already-extracted usage map, while an adapter finds
  that map inside its own payload shape, and both need the same tolerant
  string/atom key handling.
  """

  @token_fields [
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :prompt_tokens,
    :completion_tokens,
    :inputTokens,
    :outputTokens,
    :totalTokens,
    :promptTokens,
    :completionTokens,
    "input_tokens",
    "output_tokens",
    "total_tokens",
    "prompt_tokens",
    "completion_tokens",
    "inputTokens",
    "outputTokens",
    "totalTokens",
    "promptTokens",
    "completionTokens"
  ]

  @doc "The first field present in `payload` whose value reads as a non-negative integer."
  @spec get(term(), term() | [term()]) :: non_neg_integer() | nil
  def get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  def get(payload, field), do: map_integer_value(payload, field)

  @doc "A non-negative integer parsed from an integer or a numeric string, else nil."
  @spec integer_like(term()) :: non_neg_integer() | nil
  def integer_like(value) when is_integer(value) and value >= 0, do: value

  def integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  def integer_like(_value), do: nil

  @doc "Whether `payload` carries at least one recognisable token count."
  @spec integer_token_map?(term()) :: boolean()
  def integer_token_map?(payload) do
    Enum.any?(@token_fields, fn field -> !is_nil(get(payload, field)) end)
  end

  @doc "Walk a literal key path through nested maps, returning nil at the first miss."
  @spec map_at_path(term(), [term()]) :: term() | nil
  def map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  def map_at_path(_payload, _path), do: nil

  @doc "The first path in `paths` resolving to a map that carries token counts."
  @spec explicit_map_at_paths(term(), [[term()]]) :: map() | nil
  def explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  def explicit_map_at_paths(_payload, _paths), do: nil

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      payload |> Map.get(field) |> integer_like()
    else
      nil
    end
  end
end
