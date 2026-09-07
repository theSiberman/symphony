defmodule SymphonyElixirWeb.McpController do
  @moduledoc """
  HTTP transport for `SymphonyElixir.Mcp.Server`.

  One POST carries one JSON-RPC request. A notification carries no id and gets
  `202 Accepted` with no body, which is what an MCP client expects.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.Mcp.Server

  @spec rpc(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def rpc(conn, params) do
    case Server.handle(strip_phoenix_keys(params)) do
      {:reply, response} -> json(conn, response)
      :noreply -> send_resp(conn, 202, "")
    end
  end

  # Phoenix injects the action into params for path-less bodies; the JSON-RPC
  # request must reach the server exactly as the client sent it.
  defp strip_phoenix_keys(params) when is_map(params), do: Map.drop(params, ["_json_action"])
  defp strip_phoenix_keys(params), do: params
end
