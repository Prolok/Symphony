defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from WORKFLOW.md.
  """

  alias SymphonyElixir.WorkflowStore

  @workflow_file_name "WORKFLOW.md"
  @status_overview_heading "## Statusübersicht"
  @status_overview_separator ~r/^\|\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$/u
  @prompt_snippets_key "prompt_snippets"
  @render_opts [strict_variables: true, strict_filters: true]
  @direct_skip_state_names [
    "freigabe implementierung",
    "freigabe review"
  ]
  @yolo_skip_labels Enum.map(@direct_skip_state_names, &~s(skip "#{&1}"))
  @default_status_overview [
    %{status: "Backlog", next_regular_status: "Todo (AI)"},
    %{status: "Todo", next_regular_status: "Todo (AI)"},
    %{status: "Todo (AI)", next_regular_status: "Planung (AI)"},
    %{status: "Planung (AI)", next_regular_status: "In Arbeit (AI)"},
    %{status: "Planung", next_regular_status: nil},
    %{status: "In Arbeit (AI)", next_regular_status: "PreReview (AI)"},
    %{status: "PreReview (AI)", next_regular_status: "Freigabe Implementierung"},
    %{status: "Freigabe Implementierung", next_regular_status: nil},
    %{status: "Review (AI)", next_regular_status: "Freigabe Review"},
    %{status: "Freigabe Review", next_regular_status: nil},
    %{status: "Test (AI)", next_regular_status: "Merge (AI)"},
    %{status: "Merge (AI)", next_regular_status: "Review"},
    %{status: "BLOCKER", next_regular_status: nil},
    %{status: "Abbruch (AI)", next_regular_status: "Abgebrochen"},
    %{status: "Review", next_regular_status: nil},
    %{status: "Fertig", next_regular_status: nil},
    %{status: "Abgebrochen", next_regular_status: nil}
  ]

  @type status_overview_entry :: %{
          status: String.t(),
          in_scope: boolean() | nil,
          description: String.t() | nil,
          next_regular_status: String.t() | nil
        }

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    case SymphonyElixir.ProjectContext.current() do
      %{workflow_path: path} -> path
      nil -> configured_workflow_file_path()
    end
  end

  defp configured_workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      default_workflow_file_path()
  end

  @spec default_workflow_file_path() :: Path.t()
  def default_workflow_file_path do
    cwd = File.cwd!()

    self_hosting_workflow_path(cwd) ||
      case escript_script_name() do
        [] ->
          Path.join(cwd, @workflow_file_name)

        script_name ->
          script_path = List.to_string(script_name)

          if Path.basename(script_path) == "symphony" do
            script_path
            |> Path.dirname()
            |> Path.join("../#{@workflow_file_name}")
            |> Path.expand()
          else
            Path.join(cwd, @workflow_file_name)
          end
      end
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case SymphonyElixir.ProjectContext.current() do
      %{workflow: workflow} -> {:ok, workflow}
      nil -> current_unbound()
    end
  end

  defp current_unbound do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load()
    end
  end

  @spec prompt_snippet(atom() | String.t(), map()) :: String.t()
  def prompt_snippet(name, assigns \\ %{}) when (is_atom(name) or is_binary(name)) and is_map(assigns) do
    name
    |> prompt_snippet_template!()
    |> render_prompt_snippet(assigns)
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content)

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  @spec status_overview() :: {:ok, [status_overview_entry()]} | {:error, term()}
  def status_overview do
    with {:ok, %{prompt: prompt}} <- current() do
      status_overview_from_prompt(prompt)
    end
  end

  @spec status_overview_from_prompt(String.t()) :: {:ok, [status_overview_entry()]} | {:error, term()}
  def status_overview_from_prompt(prompt) when is_binary(prompt) do
    prompt
    |> status_overview_table_lines()
    |> parse_status_overview_lines()
  end

  @spec ordered_statuses() :: [String.t()]
  def ordered_statuses do
    status_overview_or_default()
    |> Enum.map(& &1.status)
  end

  @spec resolve_next_status(String.t(), [String.t()]) :: String.t() | nil
  def resolve_next_status(current_status, labels)
      when is_binary(current_status) and is_list(labels) do
    entries = status_overview_or_default()
    labels = effective_skip_labels(labels)

    entries
    |> find_status_entry(current_status)
    |> case do
      %{next_regular_status: next_regular_status} when is_binary(next_regular_status) ->
        if status_in_overview?(entries, next_regular_status) do
          resolve_target_status(next_regular_status, labels)
        else
          resolve_direct_skip_status(entries, current_status, labels)
        end

      %{status: status} ->
        resolve_direct_skip_status(entries, status, labels)

      _ ->
        nil
    end
  end

  def resolve_next_status(_current_status, _labels), do: nil

  @spec resolve_target_status(String.t(), [String.t()]) :: String.t() | nil
  def resolve_target_status(target_status, labels)
      when is_binary(target_status) and is_list(labels) do
    labels = effective_skip_labels(labels)

    status_overview_or_default()
    |> Enum.map(& &1.status)
    |> Enum.drop_while(&(normalize_status_name(&1) != normalize_status_name(target_status)))
    |> Enum.find(&(not skip_label_matches?(labels, &1)))
  end

  def resolve_target_status(_target_status, _labels), do: nil

  defp parse(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        {:ok,
         %{
           config: front_matter,
           prompt: prompt,
           prompt_template: prompt
         }}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp prompt_snippet_template!(name) do
    snippet_key = normalize_prompt_snippet_name(name)

    case current() do
      {:ok, %{config: config}} when is_map(config) ->
        prompt_snippet_from_config!(config, snippet_key)

      {:error, reason} ->
        raise RuntimeError,
              "workflow_prompt_snippet_unavailable: snippet=#{inspect(snippet_key)} reason=#{inspect(reason)}"
    end
  end

  defp normalize_prompt_snippet_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_prompt_snippet_name(name) when is_binary(name), do: name

  defp prompt_snippet_from_config!(config, snippet_key)
       when is_map(config) and is_binary(snippet_key) do
    config
    |> prompt_snippets_config!(snippet_key)
    |> prompt_snippet_value!(snippet_key)
  end

  defp prompt_snippets_config!(config, snippet_key) when is_map(config) and is_binary(snippet_key) do
    case fetch_config_value(config, @prompt_snippets_key) do
      prompt_snippets when is_map(prompt_snippets) ->
        prompt_snippets

      nil ->
        raise RuntimeError,
              "workflow_prompt_snippets_missing: snippet=#{inspect(snippet_key)}"

      other ->
        raise RuntimeError,
              "workflow_prompt_snippets_invalid: value=#{inspect(other)}"
    end
  end

  defp prompt_snippet_value!(prompt_snippets, snippet_key)
       when is_map(prompt_snippets) and is_binary(snippet_key) do
    case fetch_config_value(prompt_snippets, snippet_key) do
      template when is_binary(template) ->
        if String.trim(template) == "" do
          raise RuntimeError,
                "workflow_prompt_snippet_empty: snippet=#{inspect(snippet_key)}"
        else
          template
        end

      nil ->
        raise RuntimeError,
              "workflow_prompt_snippet_missing: snippet=#{inspect(snippet_key)}"

      other ->
        raise RuntimeError,
              "workflow_prompt_snippet_invalid: snippet=#{inspect(snippet_key)} value=#{inspect(other)}"
    end
  end

  defp fetch_config_value(config, key) when is_map(config) and is_binary(key) do
    Enum.find_value(config, fn
      {config_key, value} ->
        if to_string(config_key) == key, do: value
    end)
  end

  defp render_prompt_snippet(template, assigns) when is_binary(template) and is_map(assigns) do
    template
    |> Solid.parse!()
    |> Solid.render!(to_solid_map(assigns), @render_opts)
    |> IO.iodata_to_binary()
  rescue
    error ->
      reraise %RuntimeError{
                message: "workflow_prompt_snippet_parse_error: #{Exception.message(error)} snippet=#{inspect(template)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end

  defp self_hosting_workflow_path(start_dir) when is_binary(start_dir) do
    start_dir
    |> Path.expand()
    |> ancestor_directories()
    |> Enum.find_value(&self_hosting_workflow_candidate/1)
  end

  defp ancestor_directories(path) when is_binary(path) do
    do_ancestor_directories(path, [])
  end

  defp do_ancestor_directories(path, acc) when is_binary(path) do
    parent = Path.dirname(path)
    next_acc = [path | acc]

    if parent == path do
      Enum.reverse(next_acc)
    else
      do_ancestor_directories(parent, next_acc)
    end
  end

  defp self_hosting_workflow_candidate(directory) when is_binary(directory) do
    workflow_path = Path.join(directory, @workflow_file_name)
    mix_path = Path.join(directory, "mix.exs")

    if File.regular?(workflow_path) and symphony_mix_project?(mix_path) do
      workflow_path
    end
  end

  defp symphony_mix_project?(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        String.contains?(contents, "defmodule SymphonyElixir.MixProject") and
          String.contains?(contents, "app: :symphony_elixir")

      {:error, _reason} ->
        false
    end
  end

  defp escript_script_name do
    Application.get_env(:symphony_elixir, :escript_script_name, :escript.script_name())
  end

  defp status_overview_table_lines(prompt) when is_binary(prompt) do
    prompt
    |> String.split(~r/\R/u, trim: false)
    |> Enum.drop_while(&(String.trim(&1) != @status_overview_heading))
    |> case do
      [] ->
        []

      [_heading | rest] ->
        rest
        |> Enum.drop_while(fn line ->
          trimmed = String.trim(line)
          trimmed == "" or not status_overview_table_line?(line)
        end)
        |> Enum.take_while(&status_overview_table_line?/1)
    end
  end

  defp status_overview_table_line?(line) when is_binary(line) do
    String.starts_with?(String.trim_leading(line), "|")
  end

  defp parse_status_overview_lines([]), do: {:error, :status_overview_not_found}

  defp parse_status_overview_lines(lines) when is_list(lines) do
    entries =
      lines
      |> Enum.reject(&status_overview_separator?/1)
      |> Enum.map(&parse_status_overview_row/1)
      |> Enum.reject(&is_nil/1)

    case entries do
      [%{status: "Status"} | rest] when rest != [] -> {:ok, rest}
      [%{status: "Status"}] -> {:error, :status_overview_not_found}
      [%{} | _] = parsed_entries -> {:ok, parsed_entries}
      [] -> {:error, :status_overview_not_found}
    end
  end

  defp status_overview_separator?(line) when is_binary(line) do
    Regex.match?(@status_overview_separator, String.trim(line))
  end

  defp parse_status_overview_row(line) when is_binary(line) do
    case split_markdown_row(line) do
      [status, in_scope, description, next_regular_status | _rest] ->
        %{
          status: parse_status_cell(status),
          in_scope: parse_in_scope(in_scope),
          description: blank_to_nil(description),
          next_regular_status: parse_next_regular_status(next_regular_status)
        }

      _ ->
        nil
    end
  end

  defp split_markdown_row(line) when is_binary(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp parse_in_scope("Ja"), do: true
  defp parse_in_scope("Nein"), do: false
  defp parse_in_scope(_value), do: nil

  defp parse_status_cell(value) when is_binary(value) do
    parse_next_regular_status(value) || blank_to_nil(value)
  end

  defp parse_next_regular_status(value) when is_binary(value) do
    case Regex.run(~r/`([^`]+)`/u, value, capture: :all_but_first) do
      [status] ->
        status

      _ ->
        blank_to_nil(value)
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "-" -> nil
      trimmed -> trimmed
    end
  end

  defp skip_label_matches?(labels, state_name) when is_list(labels) and is_binary(state_name) do
    normalized_labels =
      labels
      |> Enum.map(&normalize_skip_label/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    normalized_state = normalize_status_name(state_name)

    MapSet.member?(normalized_labels, ~s(skip "#{normalized_state}")) or
      MapSet.member?(normalized_labels, "skip #{normalized_state}")
  end

  defp normalize_skip_label(label) when is_binary(label) do
    label
    |> normalize_status_name()
  end

  defp normalize_skip_label(_label), do: nil

  defp normalize_status_name(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.downcase()
  end

  defp resolve_direct_skip_status(entries, current_status, labels)
       when is_list(entries) and is_binary(current_status) and is_list(labels) do
    if direct_skip_state?(current_status) and skip_label_matches?(labels, current_status) do
      entries
      |> next_status_after(current_status)
      |> case do
        next_status when is_binary(next_status) -> resolve_target_status(next_status, labels)
        _ -> nil
      end
    end
  end

  defp direct_skip_state?(status_name) when is_binary(status_name) do
    normalized_status = normalize_status_name(status_name)
    Enum.any?(@direct_skip_state_names, &(&1 == normalized_status))
  end

  defp effective_skip_labels(labels) when is_list(labels) do
    if Application.get_env(:symphony_elixir, :yolo, false) == true do
      labels ++ @yolo_skip_labels
    else
      labels
    end
  end

  defp next_status_after(entries, current_status)
       when is_list(entries) and is_binary(current_status) do
    entries
    |> Enum.drop_while(&(normalize_status_name(&1.status) != normalize_status_name(current_status)))
    |> case do
      [_current, %{status: next_status} | _rest] -> next_status
      _ -> nil
    end
  end

  defp status_in_overview?(entries, status_name) when is_list(entries) and is_binary(status_name) do
    Enum.any?(entries, &(normalize_status_name(&1.status) == normalize_status_name(status_name)))
  end

  defp status_overview_or_default do
    case status_overview() do
      {:ok, [%{} | _] = entries} -> entries
      _ -> @default_status_overview
    end
  end

  defp find_status_entry(entries, status_name) when is_list(entries) and is_binary(status_name) do
    Enum.find(entries, &(normalize_status_name(&1.status) == normalize_status_name(status_name)))
  end
end
