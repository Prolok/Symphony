defmodule SymphonyElixir.EnvFile do
  @moduledoc """
  Loads `.env` defaults and optional `.env.local` overrides from a Symphony config directory.
  """

  @config_dir_name ".symphony"
  # Root-only settings are read by Config; project files must not export them.
  @root_only_keys ["SYM_MAXIMUM_REVIEW_ITERATIONS"]
  @env_files [
    {".env", :defaults},
    {".env.local", :local_override}
  ]

  @type load_mode :: :defaults | :local_override

  @spec config_dir(Path.t()) :: Path.t()
  def config_dir(project_root) when is_binary(project_root) do
    Path.join(project_root, @config_dir_name)
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

  @spec load(String.t()) :: :ok | {:error, term()}
  def load(config_dir) when is_binary(config_dir), do: load(config_dir, [])

  @spec load(String.t(), keyword()) :: :ok | {:error, term()}
  def load(config_dir, opts) when is_binary(config_dir) and is_list(opts) do
    override_existing = Keyword.get(opts, :override_existing, false)

    existing_keys =
      System.get_env()
      |> Map.keys()
      |> maybe_ignore_existing_keys(override_existing)
      |> MapSet.new()

    @env_files
    |> Enum.reduce_while({:ok, empty_key_set()}, fn {filename, mode}, {:ok, loaded_keys} ->
      config_dir
      |> Path.join(filename)
      |> load_file(mode, existing_keys, loaded_keys)
      |> case do
        {:ok, next_loaded_keys} -> {:cont, {:ok, next_loaded_keys}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _loaded_keys} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec maybe_ignore_existing_keys([String.t()], boolean()) :: [String.t()]
  defp maybe_ignore_existing_keys(_keys, true), do: []
  defp maybe_ignore_existing_keys(keys, false), do: keys

  defp empty_key_set, do: MapSet.delete(MapSet.new([""]), "")

  defp load_file(path, mode, existing_keys, loaded_keys) do
    env_putter = &maybe_put_env(&1, &2, mode, existing_keys, &3)
    read_file(path, loaded_keys, env_putter)
  end

  defp read_file(path, loaded_keys, env_putter) do
    case File.regular?(path) do
      true ->
        case File.read(path) do
          {:ok, contents} ->
            parse_file(contents, path, loaded_keys, env_putter)

          {:error, reason} ->
            {:error, {:env_file_read_failed, path, reason}}
        end

      false ->
        {:ok, loaded_keys}
    end
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
