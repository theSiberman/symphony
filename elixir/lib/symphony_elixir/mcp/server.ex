defmodule SymphonyElixir.Mcp.Server do
  @moduledoc """
  Model Context Protocol server exposing the configured tracker's agent tools.

  Codex receives these tools through its proprietary `dynamicTools` field at
  `thread/start`. Every other candidate runtime is an MCP client instead, so the
  same tracker binding is published here once and each future adapter gets the
  tools without a per-vendor tool layer.

  Tracker tool specs are already `{name, description, inputSchema}`, which is
  MCP's own tool shape, so `tools/list` is a pass-through. Only the call result
  needs translating: the tracker returns Codex's `contentItems`, and MCP expects
  `content`.

  This keeps `SPEC.md` §11.5 intact — tracker writes still travel through
  declared tools rather than a shell.
  """

  alias SymphonyElixir.Tracker

  @protocol_version "2025-06-18"
  @server_name "symphony-tracker"

  @doc """
  Handle one JSON-RPC request, returning the response map, or `:noreply` for a
  notification (which by JSON-RPC carries no id and must not be answered).
  """
  @spec handle(map(), keyword()) :: {:reply, map()} | :noreply
  def handle(request, opts \\ [])

  def handle(%{"method" => "initialize", "id" => id}, _opts) do
    {:reply,
     result(id, %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => %{"name" => @server_name, "version" => version()}
     })}
  end

  def handle(%{"method" => "notifications/initialized"}, _opts), do: :noreply

  def handle(%{"method" => "tools/list", "id" => id}, opts) do
    specs = opts |> tool_binding() |> Map.get(:tool_specs, []) |> Enum.map(&normalize_spec/1)

    {:reply, result(id, %{"tools" => specs})}
  end

  def handle(%{"method" => "tools/call", "id" => id} = request, opts) do
    params = Map.get(request, "params") || %{}
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments") || %{}

    case name do
      nil ->
        {:reply, error(id, -32_602, "tools/call requires a tool name")}

      name ->
        {:reply, result(id, call_tool(name, arguments, opts))}
    end
  end

  def handle(%{"id" => id, "method" => method}, _opts) do
    {:reply, error(id, -32_601, "unsupported method: #{method}")}
  end

  # A notification for a method this server does not implement is still a
  # notification: answering it would violate JSON-RPC.
  def handle(%{"method" => _method}, _opts), do: :noreply

  def handle(_request, _opts), do: {:reply, error(nil, -32_600, "invalid request")}

  @doc "Remote MCP configuration for registering this server with an opencode instance."
  @spec remote_config(String.t(), keyword()) :: map()
  def remote_config(url, opts \\ []) do
    %{"type" => "remote", "url" => url, "enabled" => true}
    |> maybe_put("headers", Keyword.get(opts, :headers))
  end

  @spec server_name() :: String.t()
  def server_name, do: @server_name

  defp call_tool(name, arguments, opts) do
    tool_binding = tool_binding(opts)

    executor =
      Keyword.get(opts, :executor, fn tool, args ->
        Tracker.execute_bound_agent_tool(tool_binding, tool, args)
      end)

    response = executor.(name, arguments)

    %{
      "content" => content_items(response),
      "isError" => Map.get(response, "success") == false
    }
  end

  # The tracker speaks Codex's contentItems; MCP wants content with text parts.
  defp content_items(%{"contentItems" => items}) when is_list(items) do
    Enum.map(items, fn item ->
      %{"type" => "text", "text" => Map.get(item, "text") || ""}
    end)
  end

  defp content_items(%{"output" => output}) when is_binary(output),
    do: [%{"type" => "text", "text" => output}]

  defp content_items(response), do: [%{"type" => "text", "text" => inspect(response)}]

  # One binding serves both list and call, so the advertised tools and the
  # executed tools can never come from different tracker settings.
  defp tool_binding(opts) do
    Keyword.get_lazy(opts, :binding, &Tracker.bind_agent_tools/0)
  end

  defp normalize_spec(spec) do
    %{
      "name" => Map.get(spec, "name"),
      "description" => Map.get(spec, "description") || "",
      "inputSchema" => Map.get(spec, "inputSchema") || %{"type" => "object"}
    }
  end

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp version do
    case :application.get_key(:symphony_elixir, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
