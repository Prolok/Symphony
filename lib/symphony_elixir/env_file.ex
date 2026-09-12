defmodule SymphonyElixir.EnvFile do
  @moduledoc """
  Loads `.env` defaults and optional `.env.local` overrides from a Symphony config directory.
  """

  @config_dir_name ".symphony"
  # Root-only settings are read by Config; project files must not export them.
  @root_only_keys ["SYM_MAXIMUM_REVIEW_ITERATIONS", "SYM_PROJECT_ROOT"]
  @env_files [
    {".env", :defaults},
    {".env.local", :local_override}
  ]

  @type load_mode :: :defaults | :local_override

  @root_config_names ~w(SYM_CODEX_MODEL SYM_CODEX_REASONING_EFFORT
    SYM_CODEX_SERVICE_TIER SYM_CODEX_HUMAN_SERVICE_TIER SYM_MAXIMUM_REVIEW_ITERATIONS SYM_PROJECT_ROOT)

  @spec root_config_names() :: [String.t()]
  def root_config_names, do: @root_config_names

  @doc "Capture only public root settings; the private source file stays outside the release."
  @spec snapshot_root(Path.t(), Path.t()) :: :ok | {:error, term()}
  def snapshot_root(root, release) do
    path = Path.join(release, ".symphony/root-config.json")

    with {:ok, values} <- read_selected([Path.join(release, ".env"), Path.join(root, ".env.local")], @root_config_names),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      values = Map.merge(values, Map.take(System.get_env(), @root_config_names))
      File.write(path, Jason.encode!(%{"root" => Path.expand(root), "values" => values}), [:exclusive])
    end
  end

  @doc "Load root launch settings and project bindings; keep the project secret out of the environment."
  @spec load_runtime(Path.t()) :: :ok | {:error, term()}
  def load_runtime(config_dir) do
    with :ok <- load_root(),
         :ok <- bind_project_dir(config_dir) do
      excluded = @root_config_names ++ SymphonyElixir.Config.linear_secret_env_names()
      load(config_dir, override_existing: true, exclude: excluded)
    end
  end

  defp bind_project_dir(config_dir) do
    directory = Path.expand(config_dir)
    current = System.get_env("SYMPHONY_LINEAR_ENV_DIR")

    if System.get_env("SYMPHONY_LINEAR_AUTH_MODE") == "app" and current not in [nil, directory] do
      {:error, :linear_runtime_binding_changed}
    else
      System.put_env("SYMPHONY_LINEAR_ENV_DIR", directory)
      :ok
    end
  end

  @spec load_root() :: :ok | {:error, term()}
  def load_root do
    with {:ok, values} <- root_config() do
      values |> Map.drop(Map.keys(System.get_env())) |> System.put_env()
      :ok
    end
  end

  defp root_config do
    case {System.get_env("SYMPHONY_ROOT_DIR"), System.get_env("SYMPHONY_RELEASE_ROOT")} do
      {nil, _} ->
        {:ok, %{}}

      {"", _} ->
        {:ok, %{}}

      {_root, release} when is_binary(release) and release != "" ->
        read_root_snapshot(Path.join(release, ".symphony/root-config.json"))

      {root, _} ->
        read_selected(Enum.map(@env_files, fn {name, _} -> Path.join(root, name) end), @root_config_names)
    end
  end

  defp read_root_snapshot(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"root" => root, "values" => values}} <- Jason.decode(body),
         true <- root == System.get_env("SYMPHONY_ROOT_DIR") and is_map(values),
         true <- Enum.all?(values, fn {key, value} -> key in @root_config_names and is_binary(value) end) do
      {:ok, values}
    else
      _ -> {:error, :invalid_root_config_snapshot}
    end
  end

  @doc "Read only the requested project secret in a trusted auth runtime; never export it."
  @spec linear_secret(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def linear_secret(name) do
    linear_secret(name, System.get_env("SYMPHONY_LINEAR_ENV_DIR"))
  end

  @spec linear_secret(String.t(), Path.t() | nil) :: {:ok, String.t()} | {:error, atom()}
  def linear_secret(name, config_dir) do
    if System.get_env("SYMPHONY_LINEAR_SECRET_ACCESS") == "denied" do
      {:error, :linear_secret_access_denied}
    else
      read_secret_file(config_dir, name)
    end
  end

  defp read_secret_file(root, name) when is_binary(root) and root != "" do
    paths = Enum.map(@env_files, fn {file, _} -> Path.join(root, file) end)

    case read_selected(paths, [name]) do
      {:ok, values} -> nonempty_secret(Map.get_lazy(values, name, fn -> System.get_env(name) end))
      _ -> {:error, :linear_secret_source_unavailable}
    end
  end

  defp read_secret_file(_root, name), do: nonempty_secret(System.get_env(name))

  defp nonempty_secret(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :missing_linear_client_secret}, else: {:ok, value}
  end

  defp nonempty_secret(_value), do: {:error, :missing_linear_client_secret}

  defp read_selected(paths, names) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, values} ->
      case read_selected_file(path, names, values) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp read_selected_file(path, names, values) do
    case File.read(path) do
      {:ok, contents} ->
        # Select by key before parsing a value: non-auth loaders do not interpret
        # secret lines, and no file is sourced or evaluated as shell code.
        selected = contents |> String.split(~r/\r\n|\n|\r/, trim: false) |> Enum.map_join("\n", &select_line(&1, names))
        parse_file(selected, path, values, fn key, value, acc -> {:ok, Map.put(acc, key, value)} end)

      {:error, :enoent} ->
        {:ok, values}

      {:error, reason} ->
        {:error, {:env_file_read_failed, path, reason}}
    end
  end

  defp select_line(line, names) do
    if line_key(line) in names, do: line, else: ""
  end

  defp line_key(line), do: line |> String.trim() |> strip_export_prefix() |> String.split("=", parts: 2) |> hd() |> String.trim()

  @spec config_dir(Path.t()) :: Path.t()
  def config_dir(project_root) when is_binary(project_root) do
    Path.join(project_root, @config_dir_name)
  end

  @doc "Read project settings without exporting variables or interpreting secret values."
  @spec read_public(Path.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def read_public(config_dir, secret_reference \\ "LINEAR_APP_SECRET") do
    paths = Enum.map(@env_files, fn {name, _} -> Path.join(config_dir, name) end)

    with {:ok, names} <- public_names(paths),
         {:ok, selected_secrets} <- selected_secret_names(paths, secret_reference) do
      read_selected(paths, names -- ["LINEAR_APP_SECRET", "LINEAR_API_KEY", "LINEAR_APP_INSTALLATION_ID" | selected_secrets])
    end
  end

  defp selected_secret_names(paths, "$" <> selector) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, names} ->
      case read_selected([path], [selector]) do
        {:ok, values} -> {:cont, {:ok, names ++ Map.values(values)}}
        error -> {:halt, error}
      end
    end)
  end

  defp selected_secret_names(_paths, reference), do: {:ok, List.wrap(reference)}

  defp public_names(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, names} ->
      case File.read(path) do
        {:ok, contents} -> {:cont, {:ok, names ++ Enum.map(String.split(contents, ~r/\r\n|\n|\r/), &line_key/1)}}
        {:error, :enoent} -> {:cont, {:ok, names}}
        {:error, reason} -> {:halt, {:error, {:env_file_read_failed, path, reason}}}
      end
    end)
  end

  @doc "Reads defaults and local overrides without changing the process environment."
  @spec read(Path.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def read(config_dir) when is_binary(config_dir) do
    Enum.reduce_while(@env_files, {:ok, %{}}, fn {filename, _mode}, {:ok, values} ->
      case read_file(Path.join(config_dir, filename), values, &{:ok, Map.put(&3, &1, &2)}) do
        {:ok, next_values} -> {:cont, {:ok, next_values}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Reuse an established project source across OTP boot and working-directory changes."
  @spec bound_config_dir() :: Path.t()
  def bound_config_dir do
    System.get_env("SYMPHONY_LINEAR_ENV_DIR") ||
      config_dir(System.get_env("SYMPHONY_PROJECT_ROOT") || System.get_env("SYMPHONY_SOURCE_REPO") || File.cwd!())
  end

  @spec load(String.t()) :: :ok | {:error, term()}
  def load(config_dir) when is_binary(config_dir), do: load(config_dir, [])

  @spec load(String.t(), keyword()) :: :ok | {:error, term()}
  def load(config_dir, opts) when is_binary(config_dir) and is_list(opts) do
    with {:ok, selected_secrets} <- project_secret_names(config_dir) do
      load_public(config_dir, opts, selected_secrets)
    end
  end

  defp project_secret_names(config_dir) do
    case SymphonyElixir.Config.linear_secret_reference() do
      "$" <> selector ->
        Enum.reduce_while(@env_files, {:ok, []}, &collect_secret_names(&1, &2, config_dir, selector))

      _ ->
        {:ok, []}
    end
  end

  defp collect_secret_names({filename, _}, {:ok, names}, config_dir, selector) do
    case read_selected([Path.join(config_dir, filename)], [selector]) do
      {:ok, values} -> {:cont, {:ok, Map.values(values) ++ names}}
      error -> {:halt, error}
    end
  end

  defp load_public(config_dir, opts, selected_secrets) do
    override_existing = Keyword.get(opts, :override_existing, false)
    excluded = selected_secrets ++ Keyword.get(opts, :exclude, []) ++ SymphonyElixir.Config.linear_secret_env_names()

    bound = protected_runtime_env()

    existing_keys =
      System.get_env()
      |> Map.keys()
      |> maybe_ignore_existing_keys(override_existing)
      |> MapSet.new()

    @env_files
    |> Enum.reduce_while({:ok, empty_key_set()}, fn {filename, mode}, {:ok, loaded_keys} ->
      config_dir
      |> Path.join(filename)
      |> load_file(mode, existing_keys, loaded_keys, excluded)
      |> case do
        {:ok, next_loaded_keys} -> {:cont, {:ok, next_loaded_keys}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _loaded_keys} -> verify_runtime_env(bound)
      {:error, reason} -> {:error, reason}
    end
  end

  defp protected_runtime_env do
    names = ~w(SYMPHONY_ROOT_DIR SYMPHONY_LINEAR_ENV_DIR SYMPHONY_LINEAR_SECRET_ACCESS)

    names =
      if System.get_env("SYMPHONY_LINEAR_AUTH_MODE") == "app",
        do: names ++ ~w(SYMPHONY_LINEAR_AUTH_MODE SYMPHONY_LINEAR_CLIENT_SECRET_ENV SYMPHONY_LINEAR_BINDING_HASH
        SYMPHONY_RELEASE_ROOT SYMPHONY_WORKFLOW_FILE SYMPHONY_WORKFLOW_DIR SYMPHONY_CODEX_STATE_ROOT),
        else: names

    System.get_env() |> Map.take(names)
  end

  defp verify_runtime_env(bound) do
    if Enum.all?(bound, fn {key, value} -> System.get_env(key) == value end) do
      :ok
    else
      System.put_env(bound)
      {:error, :linear_runtime_binding_changed}
    end
  end

  @spec maybe_ignore_existing_keys([String.t()], boolean()) :: [String.t()]
  defp maybe_ignore_existing_keys(_keys, true), do: []
  defp maybe_ignore_existing_keys(keys, false), do: keys

  defp empty_key_set, do: MapSet.delete(MapSet.new([""]), "")

  defp load_file(path, mode, existing_keys, loaded_keys, excluded) do
    env_putter = fn key, value, keys ->
      if key in excluded or key == System.get_env("SYMPHONY_LINEAR_CLIENT_SECRET_ENV"),
        do: {:ok, keys},
        else: maybe_put_env(key, value, mode, existing_keys, keys)
    end

    read_file(path, loaded_keys, env_putter, excluded)
  end

  defp read_file(path, loaded_keys, env_putter, excluded \\ []) do
    case File.regular?(path) do
      true ->
        case File.read(path) do
          {:ok, contents} ->
            parse_file(public_contents(contents, excluded), path, loaded_keys, env_putter)

          {:error, reason} ->
            {:error, {:env_file_read_failed, path, reason}}
        end

      false ->
        {:ok, loaded_keys}
    end
  end

  defp public_contents(contents, excluded) do
    contents |> String.split(~r/\r\n|\n|\r/, trim: false) |> Enum.map_join("\n", fn line -> if line_key(line) in excluded, do: "", else: line end)
  end

  @spec maybe_put_env(String.t(), String.t(), load_mode(), MapSet.t(), MapSet.t()) ::
          {:ok, MapSet.t()}
  defp maybe_put_env(key, value, mode, existing_keys, loaded_keys) do
    cond do
      key in @root_only_keys ->
        {:ok, loaded_keys}

      mode == :defaults and MapSet.member?(existing_keys, key) ->
        {:ok, loaded_keys}

      mode == :local_override and MapSet.member?(existing_keys, key) and
          not MapSet.member?(loaded_keys, key) ->
        {:ok, loaded_keys}

      true ->
        System.put_env(key, value)
        {:ok, MapSet.put(loaded_keys, key)}
    end
  end

  defp parse_file(contents, path, loaded_keys, env_putter) when is_function(env_putter, 3) do
    contents
    |> String.split(~r/\r\n|\n|\r/, trim: false)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, loaded_keys}, fn {line, line_number}, {:ok, current_loaded_keys} ->
      handle_parsed_line(parse_line(line), path, line_number, current_loaded_keys, env_putter)
    end)
  end

  defp parse_line(line) when is_binary(line) do
    case String.trim(line) do
      "" ->
        :skip

      "#" <> _comment ->
        :skip

      trimmed ->
        parse_assignment_line(trimmed)
    end
  end

  defp handle_parsed_line(:skip, _path, _line_number, current_loaded_keys, _env_putter) do
    {:cont, {:ok, current_loaded_keys}}
  end

  defp handle_parsed_line({:ok, key, value}, _path, _line_number, current_loaded_keys, env_putter) do
    {:ok, next_loaded_keys} = env_putter.(key, value, current_loaded_keys)
    {:cont, {:ok, next_loaded_keys}}
  end

  defp handle_parsed_line({:error, reason}, path, line_number, _current_loaded_keys, _env_putter) do
    {:halt, {:error, {:invalid_env_file, path, line_number, reason}}}
  end

  defp parse_assignment_line(line) do
    with {:ok, key, raw_value} <- split_assignment(strip_export_prefix(line)),
         :ok <- validate_key(key),
         {:ok, value} <- parse_value(raw_value) do
      {:ok, key, value}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp strip_export_prefix(line) do
    case String.split(line, ~r/\s+/, parts: 2) do
      ["export", rest] -> String.trim_leading(rest)
      _ -> line
    end
  end

  defp split_assignment(line) do
    case String.split(line, "=", parts: 2) do
      [raw_key, raw_value] ->
        {:ok, String.trim(raw_key), raw_value}

      _ ->
        {:error, :missing_assignment}
    end
  end

  defp validate_key(key) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) do
      :ok
    else
      {:error, :invalid_key}
    end
  end

  defp parse_value(raw_value) when is_binary(raw_value) do
    value = String.trim_leading(raw_value)

    cond do
      value == "" ->
        {:ok, ""}

      String.starts_with?(value, "\"") ->
        parse_quoted_value(value, "\"", :double)

      String.starts_with?(value, "'") ->
        parse_quoted_value(value, "'", :single)

      true ->
        {:ok, strip_inline_comment(value) |> String.trim()}
    end
  end

  defp parse_quoted_value(value, quote, quote_mode) do
    opener_size = byte_size(quote)
    remainder = binary_part(value, opener_size, byte_size(value) - opener_size)

    case take_quoted_segment(remainder, quote_mode, "") do
      {:ok, quoted, rest} ->
        case String.trim(rest) do
          "" ->
            decode_quoted_value(quoted, quote_mode)

          "#" <> _comment ->
            decode_quoted_value(quoted, quote_mode)

          _ ->
            {:error, :trailing_characters}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp take_quoted_segment(<<>>, _quote_mode, _acc), do: {:error, :unterminated_quote}

  defp take_quoted_segment(<<"\"", rest::binary>>, :double, acc), do: {:ok, acc, rest}
  defp take_quoted_segment(<<"'", rest::binary>>, :single, acc), do: {:ok, acc, rest}

  defp take_quoted_segment(<<"\\", escaped, rest::binary>>, :double, acc) do
    take_quoted_segment(rest, :double, acc <> <<?\\, escaped>>)
  end

  defp take_quoted_segment(<<char::utf8, rest::binary>>, quote_mode, acc) do
    take_quoted_segment(rest, quote_mode, acc <> <<char::utf8>>)
  end

  defp decode_quoted_value(value, :single), do: {:ok, value}

  defp decode_quoted_value(value, :double) do
    case Jason.decode("\"" <> value <> "\"") do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_escape_sequence}
    end
  end

  defp strip_inline_comment(value) do
    Regex.replace(~r/\s+#.*$/, value, "")
  end
end
