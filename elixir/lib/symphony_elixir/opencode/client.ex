defmodule SymphonyElixir.Opencode.Client do
  @moduledoc """
  HTTP client for a headless `opencode serve` instance.

  Paths and payload shapes come from the server's own OpenAPI document
  (`GET /doc`), which is the contract of record — the published documentation
  disagrees with the shipped binary on several routes. Every call takes an
  injectable `request_fun` so tests drive the adapter without a live server.
  """

  @type base_url :: String.t()

  @doc "Create a session bound to `directory`; opencode scopes a session to a project directory."
  @spec create_session(base_url(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_session(base_url, directory, opts \\ []) do
    body = opts |> Keyword.get(:body, %{}) |> Map.put_new("title", Keyword.get(opts, :title, "Symphony ticket"))

    request(:post, base_url, "/session", %{"directory" => directory}, body, opts)
  end

  @doc """
  Send one prompt and await the assistant message. Long turns need the caller's
  turn timeout rather than the default receive timeout.
  """
  @spec send_message(base_url(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_message(base_url, session_id, body, opts \\ []) do
    request(:post, base_url, "/session/#{session_id}/message", %{}, body, opts)
  end

  @doc "Stop a running session's current turn."
  @spec abort(base_url(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def abort(base_url, session_id, opts \\ []) do
    request(:post, base_url, "/session/#{session_id}/abort", %{}, %{}, opts)
  end

  @doc "Answer a permission request raised mid-turn."
  @spec reply_permission(base_url(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reply_permission(base_url, session_id, permission_id, response, opts \\ []) do
    request(
      :post,
      base_url,
      "/session/#{session_id}/permissions/#{permission_id}",
      %{},
      %{"response" => response},
      opts
    )
  end

  @doc "Register an MCP server with the running instance, exposing its tools to the agent."
  @spec register_mcp(base_url(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def register_mcp(base_url, name, config, opts \\ []) do
    request(:post, base_url, "/mcp", %{}, %{"name" => name, "config" => config}, opts)
  end

  @doc "Liveness probe used while waiting for a spawned server to accept connections."
  @spec health(base_url(), keyword()) :: {:ok, map()} | {:error, term()}
  def health(base_url, opts \\ []) do
    request(:get, base_url, "/global/health", %{}, nil, opts)
  end

  defp request(method, base_url, path, params, body, opts) do
    request_fun = Keyword.get(opts, :request_fun, &perform_request/6)
    request_fun.(method, base_url, path, params, body, opts)
  end

  defp perform_request(method, base_url, path, params, body, opts) do
    request_opts =
      [
        method: method,
        url: base_url <> path,
        params: params,
        receive_timeout: Keyword.get(opts, :receive_timeout, 30_000),
        retry: false
      ]
      |> maybe_put_json(body)
      |> maybe_put_auth(opts)

    case Req.request(request_opts) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:opencode_http_error, status, response_body}}

      {:error, reason} ->
        {:error, {:opencode_transport_error, reason}}
    end
  end

  defp maybe_put_json(request_opts, nil), do: request_opts
  defp maybe_put_json(request_opts, body), do: Keyword.put(request_opts, :json, body)

  defp maybe_put_auth(request_opts, opts) do
    case Keyword.get(opts, :password) do
      nil -> request_opts
      "" -> request_opts
      password -> Keyword.put(request_opts, :auth, {:basic, "#{Keyword.get(opts, :username, "opencode")}:#{password}"})
    end
  end
end
