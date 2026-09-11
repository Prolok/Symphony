defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, RuntimePaths, Tracker, Workflow}

  @type session_mode :: :manual | :orchestrated
  @type workflow_mode :: :automated | :interactive

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    session_mode = session_mode(opts)

    template =
      prompt_template_from_opts(opts)
      |> parse_template!()

    rendered_prompt =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map(),
          "runtime" => runtime_context(issue, session_mode, opts)
        },
        @render_opts
      )
      |> IO.iodata_to_binary()

    recovered_turn_context = Keyword.get(opts, :recovered_turn_context)

    rendered_prompt
    |> append_recovered_turn_context(issue, recovered_turn_context)
    |> append_recovered_review_subagent_wait(
      issue,
      recovered_turn_context,
      Keyword.get(opts, :recovered_review_subagent_ids)
    )
  end

  @spec build_prompt_for_issue_identifier(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_prompt_for_issue_identifier(identifier, opts \\ []) when is_binary(identifier) do
    with {:ok, issue} <- Tracker.fetch_issue_by_identifier(identifier) do
      {:ok, build_prompt(issue, opts)}
    end
  end

  @doc false
  @spec normalize_recovered_review_context(term()) :: String.t() | nil
  def normalize_recovered_review_context(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      no_findings_context?(trimmed) ->
        normalize_no_findings_context(trimmed)

      true ->
        normalize_findings_context(trimmed)
    end
  end

  def normalize_recovered_review_context(_value), do: nil

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp prompt_template_from_opts(opts) do
    case Keyword.get(opts, :prompt_template) do
      prompt when is_binary(prompt) ->
        default_prompt(prompt)

      _ ->
        Workflow.current()
        |> prompt_template!()
    end
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

  defp runtime_context(issue, session_mode, opts) do
    workflow_mode = workflow_mode(issue, session_mode)
    active_repo_root = active_repo_root(opts)
    source_repo_root = source_repo_root(opts)
    active_repo_skill_root = Path.join(active_repo_root, ".codex/skills")
    global_skill_roots = global_skill_roots()
    review_additional_hints = review_additional_hints(issue, active_repo_root)

    %{
      "local_time" => local_timestamp(),
      "timezone" => local_timezone(),
      "session_mode" => Atom.to_string(session_mode),
      "workflow_mode" => Atom.to_string(workflow_mode),
      "automated" => workflow_mode == :automated,
      "interactive" => workflow_mode == :interactive,
      "active_repo_root" => active_repo_root,
      "active_repo_skill_root" => active_repo_skill_root,
      "source_repo_root" => source_repo_root,
      "workflow_file" => workflow_file(opts),
      "workflow_dir" => Path.dirname(workflow_file(opts)),
      "maximum_review_iterations" => Config.maximum_review_iterations!(RuntimePaths.workflow_dir()),
      "docs_review_hint_enabled" => is_binary(review_additional_hints),
      "review_additional_hints" => review_additional_hints || "",
      "global_skill_roots" => global_skill_roots,
      "global_skill_roots_text" => Enum.join(global_skill_roots, ", "),
      "codex_home" => codex_home_dir() || "",
      "symphony_executable_dir" => symphony_executable_dir() || ""
    }
  end

  defp workflow_mode(%{state: state}, :orchestrated) when is_binary(state) do
    if automated_issue_state?(state) do
      :automated
    else
      :interactive
    end
  end

  defp workflow_mode(%{state: state}, _session_mode) when is_binary(state) do
    if automated_issue_state?(state) do
      :automated
    else
      :interactive
    end
  end

  defp workflow_mode(_issue, _session_mode), do: :interactive

  defp automated_issue_state?(state) when is_binary(state) do
    String.ends_with?(String.trim(state), "(AI)")
  end

  defp session_mode(opts) do
    case Keyword.get(opts, :session_mode, :orchestrated) do
      :manual -> :manual
      :orchestrated -> :orchestrated
      _ -> :orchestrated
    end
  end

  defp local_timestamp do
    NaiveDateTime.local_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end

  defp local_timezone do
    case System.get_env("TZ") do
      timezone when is_binary(timezone) ->
        case String.trim(timezone) do
          "" -> "system-local"
          trimmed -> trimmed
        end

      _ ->
        "system-local"
    end
  end

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp review_additional_hints(%{state: state}, active_repo_root)
       when is_binary(state) and is_binary(active_repo_root) do
    if String.trim(state) == "Review (AI)" and File.dir?(Path.join(active_repo_root, "docs")) do
      """
      - Das aktive Repository enthält ein `docs/`-Verzeichnis.
      - Prüfe Dokumentationskonsistenz und mögliche Dokumentationsdrift zwischen Code, Workflow-/Skill-Texten und Inhalten unter `docs/`.
      - Reiche diesen Hinweis in der bestehenden Delegationskette bis zum verpflichtenden read-only Review-Subagenten weiter.
      - Melde nötige Doku-Anpassungen als reguläre Findings.
      """
      |> String.trim()
    end
  end

  defp review_additional_hints(_issue, _active_repo_root), do: nil

  defp append_recovered_turn_context(prompt, %{state: state}, context)
       when is_binary(prompt) and is_binary(state) do
    trimmed_context = valid_review_recovered_context(state, context)

    if is_nil(trimmed_context) do
      prompt
    else
      prompt <>
        "\n\n" <> Workflow.prompt_snippet("recovered_turn_context", %{context: trimmed_context})
    end
  end

  defp append_recovered_turn_context(prompt, _issue, _context), do: prompt

  defp append_recovered_review_subagent_wait(
         prompt,
         %{state: state},
         recovered_turn_context,
         review_subagent_ids
       )
       when is_binary(prompt) and is_binary(state) do
    if valid_review_recovered_context(state, recovered_turn_context) do
      prompt
    else
      case valid_recovered_review_subagent_ids(state, review_subagent_ids) do
        [] ->
          prompt

        agent_ids ->
          prompt <>
            "\n\n" <>
            Workflow.prompt_snippet("recovered_review_subagent_wait", %{
              agent_ids_text: Enum.join(agent_ids, "\n")
            })
      end
    end
  end

  defp append_recovered_review_subagent_wait(prompt, _issue, _context, _review_subagent_ids),
    do: prompt

  defp valid_review_recovered_context(state, context)
       when is_binary(state) and is_binary(context) do
    trimmed_state =
      state
      |> String.trim()
      |> String.downcase()

    trimmed_context = String.trim(context)

    cond do
      trimmed_state != "review (ai)" -> nil
      trimmed_context == "" -> nil
      true -> normalize_recovered_review_context(trimmed_context) || trimmed_context
    end
  end

  defp valid_review_recovered_context(_state, _context), do: nil

  defp valid_recovered_review_subagent_ids(state, review_subagent_ids)
       when is_binary(state) do
    trimmed_state =
      state
      |> String.trim()
      |> String.downcase()

    if trimmed_state == "review (ai)" do
      review_subagent_ids
      |> normalize_recovered_review_subagent_ids()
      |> Enum.to_list()
      |> Enum.sort()
    else
      []
    end
  end

  defp normalize_recovered_review_subagent_ids(value) when is_struct(value, MapSet), do: value

  defp normalize_recovered_review_subagent_ids(value) when is_list(value) do
    value
    |> Enum.filter(&valid_recovered_review_subagent_id?/1)
    |> Enum.map(&String.trim/1)
    |> MapSet.new()
  end

  defp normalize_recovered_review_subagent_ids(_value), do: MapSet.new()

  defp valid_recovered_review_subagent_id?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_recovered_review_subagent_id?(_value), do: false

  defp no_findings_context?(value) when is_binary(value) do
    String.match?(value, ~r/^(?:keine(?:\s+konkreten)? findings|no(?:\s+concrete)? findings)(?:[.!:]|\s|$)/iu)
  end

  defp normalize_no_findings_context(value) when is_binary(value) do
    [rest] =
      Regex.run(
        ~r/^(?:keine(?:\s+konkreten)? findings|no(?:\s+concrete)? findings)(?:[.!:]?)(?:\s*\n)?\s*(.*)$/isu,
        value,
        capture: :all_but_first
      )

    append_no_findings_suffix(String.trim(rest))
  end

  defp normalize_findings_context(value) when is_binary(value) do
    case Regex.run(
           ~r/^(?:\*\*findings\*\*|findings)(?:\s*:)?(?:\s*\n)?\s*(.*)$/isu,
           value,
           capture: :all_but_first
         ) do
      [rest] ->
        append_findings_suffix(String.trim(rest))

      _ ->
        normalize_implicit_findings_context(value)
    end
  end

  defp normalize_implicit_findings_context(value) when is_binary(value) do
    if implicit_findings_context?(value) do
      append_findings_suffix(String.trim(value))
    end
  end

  defp implicit_findings_context?(value) when is_binary(value) do
    String.match?(value, ~r/^(?:[-*+]\s+\S|\d+\.\s+\S)/u)
  end

  defp append_no_findings_suffix(""), do: "Keine Findings."
  defp append_no_findings_suffix(rest), do: "Keine Findings.\n" <> rest

  defp append_findings_suffix(""), do: "Findings:"
  defp append_findings_suffix(rest), do: "Findings:\n" <> rest

  defp active_repo_root(opts) do
    opts
    |> Keyword.get(:active_repo_root)
    |> present_path()
    |> case do
      nil ->
        System.get_env("SYMPHONY_ACTIVE_REPO_ROOT")
        |> present_path()
        |> Kernel.||(source_repo_root(opts))

      path ->
        path
    end
  end

  defp source_repo_root(opts) do
    opts
    |> Keyword.get(:source_repo_root)
    |> present_path()
    |> case do
      nil ->
        System.get_env("SYMPHONY_SOURCE_REPO")
        |> present_path()
        |> Kernel.||(Path.dirname(workflow_file(opts)))

      path ->
        path
    end
  end

  defp workflow_file(opts) do
    opts
    |> Keyword.get(:workflow_file)
    |> present_path()
    |> case do
      nil ->
        System.get_env("SYMPHONY_WORKFLOW_FILE")
        |> present_path()
        |> Kernel.||(Workflow.workflow_file_path())

      path ->
        path
    end
  end

  defp global_skill_roots do
    [
      codex_home_dir() && Path.join(codex_home_dir(), "skills"),
      symphony_executable_dir()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp codex_home_dir do
    case System.get_env("CODEX_HOME") do
      home when is_binary(home) and home != "" ->
        Path.expand(home)

      _ ->
        case user_home_dir() do
          home when is_binary(home) and home != "" -> Path.join(home, ".codex")
          _ -> nil
        end
    end
  end

  defp symphony_executable_dir do
    case System.find_executable("symphony") do
      nil ->
        Application.get_env(:symphony_elixir, :escript_script_name)
        |> executable_dir_from_script_name()

      path ->
        Path.dirname(path)
    end
  end

  defp executable_dir_from_script_name(script_name) when is_list(script_name) do
    script_name
    |> List.to_string()
    |> executable_dir_from_script_name()
  end

  defp executable_dir_from_script_name(script_name) when is_binary(script_name) do
    if Path.basename(script_name) == "symphony" do
      Path.dirname(script_name)
    end
  end

  defp executable_dir_from_script_name(_script_name), do: nil

  defp user_home_dir do
    Application.get_env(:symphony_elixir, :prompt_builder_user_home, System.user_home())
  end

  defp present_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> nil
      trimmed -> Path.expand(trimmed)
    end
  end

  defp present_path(_path), do: nil
end
