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

  @doc """
  Streamable-HTTP clients open `GET /mcp` for the server-to-client SSE channel.

  This server never initiates messages, so the transport spec's other permitted
  answer applies: 405 with an `allow` header. A 404 would tell the client it had
  the wrong URL and invite a retry against a different path; 405 tells it this
  endpoint exists and simply offers no stream, which is what opencode needs to
  settle on POST-only and stop probing.
  """
  @spec stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def stream(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  # Phoenix injects the action into params for path-less bodies; the JSON-RPC
  # request must reach the server exactly as the client sent it.
  defp strip_phoenix_keys(params) when is_map(params), do: Map.drop(params, ["_json_action"])
  defp strip_phoenix_keys(params), do: params
end
