defmodule SymphonyElixir.EnvFileTest do
  use ExUnit.Case

  alias SymphonyElixir.EnvFile

  test "reads merged root values without exporting defaults or overriding the environment" do
    root = temp_project_root("read-values")
    on_exit(fn -> File.rm_rf(root) end)
    before_env = System.get_env()

    assert {:ok, %{}} = EnvFile.read(root)

    File.write!(Path.join(root, ".env"), "LINEAR_API_KEY=root-key\nSYM_MAXIMUM_REVIEW_ITERATIONS=3\n")
    File.write!(Path.join(root, ".env.local"), "export SYM_MAXIMUM_REVIEW_ITERATIONS = ' 5 ' # local\n")

    assert {:ok, %{"LINEAR_API_KEY" => "root-key", "SYM_MAXIMUM_REVIEW_ITERATIONS" => " 5 "}} = EnvFile.read(root)
    assert System.get_env() == before_env

    File.write!(Path.join(root, ".env.local"), "INVALID\n")
    assert {:error, {:invalid_env_file, path, 1, :missing_assignment}} = EnvFile.read(root)
    assert path == Path.join(root, ".env.local")
    assert System.get_env() == before_env
  end

  test "loads .symphony/.env and lets .symphony/.env.local override repo defaults" do
    project_root = temp_project_root("load-order")
    env_dir = symphony_dir(project_root)
    previous_api_key = System.get_env("LINEAR_API_KEY")
    previous_assignee = System.get_env("LINEAR_ASSIGNEE")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
      restore_env("LINEAR_ASSIGNEE", previous_assignee)
      File.rm_rf(project_root)
    end)

    System.delete_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_ASSIGNEE")

    File.write!(Path.join(env_dir, ".env"), "LINEAR_API_KEY=shared-key\nLINEAR_ASSIGNEE=team@example.com\n")
    File.write!(Path.join(env_dir, ".env.local"), "LINEAR_ASSIGNEE=dev@example.com\n")

    assert :ok = EnvFile.load(env_dir)
    assert System.get_env("LINEAR_API_KEY") == "shared-key"
    assert System.get_env("LINEAR_ASSIGNEE") == "dev@example.com"
  end

  test "preserves externally provided env vars over .env files" do
    project_root = temp_project_root("preserve-system-env")
    env_dir = symphony_dir(project_root)
    previous_api_key = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
      File.rm_rf(project_root)
    end)

    System.put_env("LINEAR_API_KEY", "shell-key")
    File.write!(Path.join(env_dir, ".env"), "LINEAR_API_KEY=repo-key\n")
    File.write!(Path.join(env_dir, ".env.local"), "LINEAR_API_KEY=local-key\n")

    assert :ok = EnvFile.load(env_dir)
    assert System.get_env("LINEAR_API_KEY") == "shell-key"
  end

  test "can explicitly let project env files override inherited env vars" do
    project_root = temp_project_root("override-system-env")
    env_dir = symphony_dir(project_root)
    previous_api_key = System.get_env("LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
      File.rm_rf(project_root)
    end)

    System.put_env("LINEAR_API_KEY", "shell-key")
    File.write!(Path.join(env_dir, ".env"), "LINEAR_API_KEY=repo-key\n")
    File.write!(Path.join(env_dir, ".env.local"), "LINEAR_API_KEY=local-key\n")

    assert :ok = EnvFile.load(env_dir, override_existing: true)
    assert System.get_env("LINEAR_API_KEY") == "local-key"
  end

  test "supports quoted values and comments" do
    project_root = temp_project_root("quoted-values")
    env_dir = symphony_dir(project_root)
    previous_assignee = System.get_env("LINEAR_ASSIGNEE")

    on_exit(fn ->
      restore_env("LINEAR_ASSIGNEE", previous_assignee)
      File.rm_rf(project_root)
    end)

    System.delete_env("LINEAR_ASSIGNEE")

    File.write!(
      Path.join(env_dir, ".env"),
      ~s(LINEAR_ASSIGNEE="Dev Example <dev@example.com>" # local owner\n)
    )

    assert :ok = EnvFile.load(env_dir)
    assert System.get_env("LINEAR_ASSIGNEE") == "Dev Example <dev@example.com>"
  end

  test "returns a clear error for invalid lines" do
    project_root = temp_project_root("invalid-line")
    env_dir = symphony_dir(project_root)

    on_exit(fn ->
      File.rm_rf(project_root)
    end)

    File.write!(Path.join(env_dir, ".env"), "LINEAR_API_KEY\n")

    assert {:error, {:invalid_env_file, path, 1, :missing_assignment}} = EnvFile.load(env_dir)
    assert path == Path.join(env_dir, ".env")
  end

  test "ignores blank lines and full-line comments" do
    project_root = temp_project_root("comments")
    env_dir = symphony_dir(project_root)
    previous_api_key = System.get_env("LINEAR_API_KEY")
    previous_exported = System.get_env("EXPORTED_KEY")
    previous_empty = System.get_env("EMPTY_VALUE")
    previous_single = System.get_env("SINGLE_QUOTED")
    previous_double = System.get_env("DOUBLE_ESCAPED")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
      restore_env("EXPORTED_KEY", previous_exported)
      restore_env("EMPTY_VALUE", previous_empty)
      restore_env("SINGLE_QUOTED", previous_single)
      restore_env("DOUBLE_ESCAPED", previous_double)
      File.rm_rf(project_root)
    end)

    System.delete_env("LINEAR_API_KEY")
    System.delete_env("EXPORTED_KEY")
    System.delete_env("EMPTY_VALUE")
    System.delete_env("SINGLE_QUOTED")
    System.delete_env("DOUBLE_ESCAPED")

    File.write!(
      Path.join(env_dir, ".env"),
      [
        "\n",
        "# shared comment\n",
        "LINEAR_API_KEY=comment-key\n",
        "export EXPORTED_KEY=exported\n",
        "EMPTY_VALUE=\n",
        "SINGLE_QUOTED='single quoted value'\n",
        ~s(DOUBLE_ESCAPED="line\\nvalue") <> "\n"
      ]
    )

    assert :ok = EnvFile.load(env_dir)
    assert System.get_env("LINEAR_API_KEY") == "comment-key"
    assert System.get_env("EXPORTED_KEY") == "exported"
    assert System.get_env("EMPTY_VALUE") == ""
    assert System.get_env("SINGLE_QUOTED") == "single quoted value"
    assert System.get_env("DOUBLE_ESCAPED") == "line\nvalue"
  end

  test "succeeds when .env files are absent" do
    project_root = temp_project_root("missing-files")
    env_dir = symphony_dir(project_root)

    on_exit(fn ->
      File.rm_rf(project_root)
    end)

    assert :ok = EnvFile.load(env_dir)
  end

  test "returns a clear error when an env file cannot be read" do
    project_root = temp_project_root("read-failure")
    env_path = Path.join(symphony_dir(project_root), ".env")

    on_exit(fn ->
      File.chmod(env_path, 0o600)
      File.rm_rf(project_root)
    end)

    File.write!(env_path, "LINEAR_API_KEY=secret\n")
    File.chmod!(env_path, 0o000)

    assert {:error, {:env_file_read_failed, path, reason}} = EnvFile.load(symphony_dir(project_root))
    assert path == env_path
    assert reason in [:eacces, :eperm]
  end

  test "returns a clear error for trailing characters after a quoted value" do
    project_root = temp_project_root("trailing-characters")
    env_dir = symphony_dir(project_root)

    on_exit(fn ->
      File.rm_rf(project_root)
    end)

    File.write!(Path.join(env_dir, ".env"), ~s(LINEAR_API_KEY="value" trailing\n))

    assert {:error, {:invalid_env_file, path, 1, :trailing_characters}} = EnvFile.load(env_dir)
    assert path == Path.join(env_dir, ".env")
  end

  test "returns a clear error for unterminated quoted values" do
    project_root = temp_project_root("unterminated-quote")
    env_dir = symphony_dir(project_root)

    on_exit(fn ->
      File.rm_rf(project_root)
    end)

    File.write!(Path.join(env_dir, ".env"), ~s(LINEAR_API_KEY="value\n))

    assert {:error, {:invalid_env_file, path, 1, :unterminated_quote}} = EnvFile.load(env_dir)
    assert path == Path.join(env_dir, ".env")
  end

  test "returns a clear error for invalid escape sequences in double-quoted values" do
    project_root = temp_project_root("invalid-escape")
    env_dir = symphony_dir(project_root)

    on_exit(fn ->
      File.rm_rf(project_root)
    end)

    File.write!(Path.join(env_dir, ".env"), ~s(LINEAR_API_KEY="\\x"\n))

    assert {:error, {:invalid_env_file, path, 1, :invalid_escape_sequence}} = EnvFile.load(env_dir)
    assert path == Path.join(env_dir, ".env")
  end

  defp temp_project_root(suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-env-file-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(symphony_dir(path))
    path
  end

  defp symphony_dir(project_root), do: EnvFile.config_dir(project_root)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
