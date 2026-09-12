defmodule SymphonyElixir.Codex.Watch do
  @moduledoc """
  Terminal watcher for a running Codex session exposed by Symphony observability.
  """

  alias SymphonyElixir.Config

  @default_port 4000
  @default_interval_ms 1_000

  @type watch_state :: %{
          seen: MapSet.t(),
          session_id: String.t() | nil,
          waiting?: boolean(),
          api_error?: boolean(),
          stream_open?: boolean()
        }

  @spec main([String.t()]) :: :ok
  def main(args), do: main(args, [])

  @spec main([String.t()], keyword()) :: :ok
  def main(args, opts) when is_list(args) and is_list(opts) do
    case parse_args(args) do
      {:ok, :help} ->
        print_usage(:stdio)

      {:ok, config} ->
        Application.ensure_all_started(:req)
        output_fun = Keyword.get(opts, :output_fun, &IO.puts/1)
        write_fun = Keyword.get(opts, :write_fun, &IO.write/1)
        sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
        req_fun = Keyword.get(opts, :req_fun, &Req.get/1)
        once? = Keyword.get(opts, :once?, config.once?)
        config = %{config | once?: once?, base_url: config.base_url || default_base_url()}

        output_fun.("sym-watch #{config.issue_identifier} -> #{config.base_url}")
        watch_loop(config, initial_state(), output_fun, write_fun, sleep_fun, req_fun)

      {:error, message} ->
        IO.puts(:stderr, "sym-watch: #{message}")
        print_usage(:stderr)
        System.halt(1)
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args,
           strict: [url: :string, interval_ms: :integer, once: :boolean, help: :boolean],
           aliases: [h: :help]
         ) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false) do
          {:ok, :help}
        else
          {:error, "missing issue identifier"}
        end

      {opts, [issue_identifier], []} ->
        if Keyword.get(opts, :help, false) do
          {:ok, :help}
        else
          build_config(issue_identifier, opts)
        end

      {_opts, [_issue_identifier | extra], []} ->
        {:error, "unexpected positional arguments: #{Enum.join(extra, " ")}"}

      {_opts, _args, invalid} ->
        {option, _value} = List.first(invalid)
        {:error, "unknown option: #{option}"}
    end
  end

  defp build_config(issue_identifier, opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    if interval_ms > 0 do
      {:ok,
       %{
         issue_identifier: issue_identifier,
         base_url: Keyword.get(opts, :url),
         interval_ms: interval_ms,
         once?: Keyword.get(opts, :once, false)
       }}
    else
      {:error, "--interval-ms must be greater than 0"}
    end
  end

  defp print_usage(device) do
    IO.puts(device, """
    Usage:
      sym-watch [--url <observability-url>] [--interval-ms <ms>] <issue.identifier>

    Watches the Symphony observability API for the issue and prints Codex session events.
    If no session is running, sym-watch waits until the next session appears.
    """)
  end

  defp initial_state do
    %{seen: MapSet.new(), session_id: nil, waiting?: false, api_error?: false, stream_open?: false}
  end

  defp default_base_url do
    System.get_env("SYMPHONY_WATCH_URL") ||
      System.get_env("SYMPHONY_OBSERVABILITY_URL") ||
      configured_base_url()
  end

  defp configured_base_url do
    settings = Config.settings!()
    port = Config.server_port() || @default_port
    host = connectable_host(settings.server.host)
    "http://#{host}:#{port}"
  end

  defp connectable_host(host) when host in [nil, "", "0.0.0.0", "::"], do: "127.0.0.1"
  defp connectable_host(host), do: host

  defp watch_loop(config, state, output_fun, write_fun, sleep_fun, req_fun) do
    {state, output} =
      config
      |> issue_url()
      |> fetch_issue(req_fun)
      |> render_poll_result(config, state)

    emit_output(output, output_fun, write_fun)

    if config.once? do
      :ok
    else
      sleep_fun.(config.interval_ms)
      watch_loop(config, state, output_fun, write_fun, sleep_fun, req_fun)
    end
  end

  defp emit_output(output, output_fun, write_fun) do
    Enum.each(output, fn
      {:line, line} -> output_fun.(line)
      {:write, text} -> write_fun.(text)
    end)
  end

  defp issue_url(%{base_url: base_url, issue_identifier: issue_identifier}) do
    encoded_identifier = URI.encode(issue_identifier, &URI.char_unreserved?/1)
    String.trim_trailing(base_url, "/") <> "/api/v1/" <> encoded_identifier
  end

  defp fetch_issue(url, req_fun) do
    req_fun.(url: url, retry: false)
  rescue
    error in [Req.TransportError, RuntimeError] -> {:error, error}
  end

  defp render_poll_result({:ok, %{status: 200, body: body}}, config, state) when is_map(body) do
    render_issue_payload(body, config.issue_identifier, %{state | api_error?: false})
  end

  defp render_poll_result({:ok, %{status: 404}}, config, state) do
    render_waiting(config.issue_identifier, %{state | api_error?: false})
  end

  defp render_poll_result({:ok, %{status: 409}}, _config, state) do
    render_api_error("Mehrdeutige Ticketkennung; sym-watch Projekt:Ticketkennung verwenden.", state)
  end

  defp render_poll_result({:ok, %{status: status}}, _config, state) do
    render_api_error("Observability API returned HTTP #{status}", state)
  end

  defp render_poll_result({:error, reason}, config, state) do
    render_api_unavailable(config.base_url, reason, state)
  end

  defp render_issue_payload(%{"running" => nil}, issue_identifier, state), do: render_waiting(issue_identifier, state)

  defp render_issue_payload(payload, issue_identifier, state) do
    session_id = get_in(payload, ["running", "session_id"])

    if is_binary(session_id) and String.trim(session_id) != "" do
      events = Map.get(payload, "recent_events", [])
      next_state = reset_stream_for_new_session(session_id, %{state | waiting?: false})
      {next_state, output} = render_running_events(events, session_id, next_state)
      header = session_header(session_id, state)
      session_prefix = stream_close_for_new_session(session_id, state)
      {%{next_state | session_id: session_id}, Enum.reject(session_prefix ++ [header | output], &is_nil/1)}
    else
      render_waiting(issue_identifier, state)
    end
  end

  defp reset_stream_for_new_session(session_id, %{session_id: session_id} = state), do: state
  defp reset_stream_for_new_session(_session_id, state), do: %{state | stream_open?: false}

  defp stream_close_for_new_session(session_id, %{session_id: session_id}), do: []
  defp stream_close_for_new_session(_session_id, state), do: close_stream(state)

  defp render_running_events(events, session_id, state) when is_list(events) do
    Enum.reduce(events, {state, []}, &render_running_event(&1, &2, session_id))
  end

  defp render_running_events(_events, _session_id, state), do: {state, []}

  defp render_running_event(event, {state, lines}, session_id) do
    if current_session_event?(event, session_id) do
      append_unseen_event(event, session_id, state, lines)
    else
      {state, lines}
    end
  end

  defp append_unseen_event(event, session_id, state, lines) do
    key = event_key(event, session_id)

    if MapSet.member?(state.seen, key) do
      {state, lines}
    else
      state = %{state | seen: MapSet.put(state.seen, key)}
      {state, output} = format_event(event, state)
      {state, lines ++ output}
    end
  end

  defp current_session_event?(event, session_id) do
    case event_session_id(event) do
      nil -> true
      ^session_id -> true
      _event_session_id -> false
    end
  end

  defp session_header(session_id, %{session_id: session_id}), do: nil
  defp session_header(session_id, _state), do: {:line, "== Codex session #{session_id} =="}

  defp render_waiting(_issue_identifier, %{waiting?: true} = state), do: {state, []}

  defp render_waiting(issue_identifier, state) do
    {%{state | waiting?: true, stream_open?: false}, close_stream(state) ++ [{:line, "Warte auf Codex-Sitzung für #{issue_identifier} ..."}]}
  end

  defp render_api_error(_message, %{api_error?: true} = state), do: {state, []}

  defp render_api_error(message, state) do
    {%{state | api_error?: true, stream_open?: false}, close_stream(state) ++ [{:line, message}]}
  end

  defp render_api_unavailable(_base_url, _reason, %{api_error?: true} = state), do: {state, []}

  defp render_api_unavailable(base_url, reason, state) do
    message =
      "Warte auf Symphony-Observability-API unter #{base_url} (#{Exception.message(reason)}). " <>
        "Starte Symphony mit `./symphony` oder setze `--url`."

    {%{state | api_error?: true, stream_open?: false}, close_stream(state) ++ [{:line, message}]}
  end

  defp event_key(event, session_id) do
    event_session_id = event_session_id(event) || session_id

    case event_sequence(event) do
      nil -> {event_session_id, Map.get(event, "at"), Map.get(event, "event"), Map.get(event, "message")}
      sequence -> {event_session_id, sequence}
    end
  end

  defp event_session_id(event) when is_map(event), do: Map.get(event, "session_id")
  defp event_session_id(_event), do: nil

  defp event_sequence(event) when is_map(event), do: Map.get(event, "sequence")
  defp event_sequence(_event), do: nil

  defp format_event(event, state) do
    event
    |> Map.get("message")
    |> normalize_message()
    |> interesting_output(state)
  end

  defp normalize_message(message) when is_binary(message) do
    String.replace_prefix(message, "notification: ", "")
  end

  defp normalize_message(_message), do: ""

  defp interesting_output("", state), do: {state, []}

  defp interesting_output(message, state) do
    cond do
      ignored_message?(String.trim(message)) ->
        trimmed_message = String.trim(message)

        if trimmed_message == "item completed: agent message" or String.starts_with?(trimmed_message, "item completed: agent message ") do
          {%{state | stream_open?: false}, close_stream(state)}
        else
          {state, []}
        end

      stream_text = stream_text(message) ->
        {%{state | stream_open?: true}, [{:write, stream_text}]}

      true ->
        {%{state | stream_open?: false}, close_stream(state) ++ [{:line, String.trim(message)}]}
    end
  end

  defp stream_text(message) do
    Enum.find_value(stream_prefixes(), fn prefix ->
      if String.starts_with?(message, prefix) do
        String.replace_prefix(message, prefix, "")
      end
    end)
  end

  defp stream_prefixes do
    [
      "agent message streaming: ",
      "agent message content streaming: ",
      "plan streaming: ",
      "command output streaming: ",
      "file change output streaming: "
    ]
  end

  defp ignored_message?(message) do
    Enum.any?(ignored_prefixes(), &String.starts_with?(message, &1)) or
      message in ignored_messages()
  end

  defp ignored_prefixes do
    [
      "item started: user message",
      "item completed: user message",
      "item started: reasoning",
      "item completed: reasoning",
      "item started: agent message",
      "item completed: agent message",
      "item started: command execution",
      "item completed: command execution",
      "rate limits updated:",
      "thread token usage updated",
      "turn started",
      "mcp startup:",
      "token count update",
      "reasoning streaming",
      "reasoning content streaming",
      "reasoning summary streaming",
      "reasoning summary section added",
      "reasoning text streaming"
    ]
  end

  defp ignored_messages do
    [
      "thread/status/changed",
      "mcpServer/startupStatus/updated",
      "mcp startup complete",
      "task started",
      "user message received",
      "agent message streaming",
      "agent message content streaming",
      "plan streaming",
      "command output streaming",
      "file change output streaming"
    ]
  end

  defp close_stream(%{stream_open?: true}), do: [{:write, "\n"}]
  defp close_stream(_state), do: []
end
