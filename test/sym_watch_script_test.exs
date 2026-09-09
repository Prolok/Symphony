defmodule SymWatchScriptTest do
  use ExUnit.Case, async: true

  @script_source Path.expand("../sym-watch", __DIR__)
  @mix_runtime_source Path.expand("../scripts/mix-runtime", __DIR__)

  test "sym-watch runs the Elixir watcher with forwarded arguments" do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-watch"), bin_dir, [
               "--url",
               "http://127.0.0.1:4000",
               "--once",
               "PRO-265"
             ])

    assert output =~ "watch-expr=SymphonyElixir.Codex.Watch.main(System.argv())"
    assert output =~ "watch-args=--url http://127.0.0.1:4000 --once PRO-265"
    assert output =~ "mix-calls=deps.loadpaths compile run"
  end

  test "sym-watch fetches dependencies only when the dependency check fails" do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!(deps_loadpaths_status: 1)

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {output, 0} =
             run_script(Path.join(repo_dir, "sym-watch"), bin_dir, [
               "--url",
               "http://127.0.0.1:4000",
               "--once",
               "PRO-265"
             ])

    assert output =~ "mix-calls=deps.loadpaths deps.get compile run"
  end

  test "sym-watch ignores inherited Mix artifact paths" do
    %{repo_dir: repo_dir, bin_dir: bin_dir} = build_script_fixture!()
    foreign_deps = Path.join(repo_dir, "foreign-deps")
    foreign_build = Path.join(repo_dir, "foreign-build")

    File.mkdir_p!(foreign_deps)
    File.mkdir_p!(foreign_build)
    File.write!(Path.join(foreign_deps, "sentinel"), "newer checkout deps\n")
    File.write!(Path.join(foreign_build, "sentinel"), "newer checkout build\n")

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(bin_dir)
    end)

    assert {_output, 0} =
             run_script(Path.join(repo_dir, "sym-watch"), bin_dir, ["--once", "PRO-608"],
               env: [
                 {"MIX_DEPS_PATH", foreign_deps},
                 {"MIX_BUILD_ROOT", foreign_build},
                 {"MIX_BUILD_PATH", foreign_build}
               ]
             )

    assert File.ls!(foreign_deps) == ["sentinel"]
    assert File.ls!(foreign_build) == ["sentinel"]
    assert File.exists?(Path.join(repo_dir, "deps/sym-watch-touch"))
    assert File.exists?(Path.join(repo_dir, "_build/sym-watch-touch"))
  end

  defp build_script_fixture!(opts \\ []) do
    repo_dir = Path.join(System.tmp_dir!(), "sym-watch-script-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(System.tmp_dir!(), "sym-watch-bin-#{System.unique_integer([:positive])}")
    mix_path = Path.join(bin_dir, "mix")
    mise_path = Path.join(bin_dir, "mise")
    deps_loadpaths_status = Keyword.get(opts, :deps_loadpaths_status, 0)

    File.mkdir_p!(repo_dir)
    File.mkdir_p!(Path.join(repo_dir, "scripts"))
    File.mkdir_p!(bin_dir)
    File.cp!(@script_source, Path.join(repo_dir, "sym-watch"))
    File.cp!(@mix_runtime_source, Path.join(repo_dir, "scripts/mix-runtime"))

    File.write!(mix_path, """
    #!/usr/bin/env bash
    calls_file="$PWD/.mix-calls"
    deps_path="${MIX_DEPS_PATH:-$PWD/deps}"
    build_path="${MIX_BUILD_PATH:-${MIX_BUILD_ROOT:-$PWD/_build}}"
    mkdir -p "$deps_path" "$build_path"
    printf '%s\\n' "$1" >> "$deps_path/sym-watch-touch"
    printf '%s\\n' "$1" >> "$build_path/sym-watch-touch"

    if [ "$1" = "deps.loadpaths" ]; then
      printf '%s\\n' "$1" >> "$calls_file"
      exit #{deps_loadpaths_status}
    fi

    if [ "$1" = "deps.get" ]; then
      printf '%s\\n' "$1" >> "$calls_file"
      exit 0
    fi

    if [ "$1" = "compile" ]; then
      printf '%s\\n' "$1" >> "$calls_file"
      exit 0
    fi

    if [ "$1" = "run" ]; then
      printf '%s\\n' "$1" >> "$calls_file"
      shift
      expr=""

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --no-start|--no-compile)
            shift
            ;;
          -e)
            expr="$2"
            shift 2
            ;;
          --)
            shift
            break
            ;;
          *)
            printf 'unexpected mix run arg=%s\\n' "$1" >&2
            exit 1
            ;;
        esac
      done

      printf 'watch-expr=%s\\nwatch-args=%s\\n' "$expr" "$*"
      printf 'mix-calls=%s\\n' "$(tr '\\n' ' ' < "$calls_file" | sed 's/ $//')"
      exit 0
    fi

    printf 'unexpected mix args=%s\\n' "$*" >&2
    exit 1
    """)

    File.write!(mise_path, """
    #!/usr/bin/env bash
    if [ "$1" = "exec" ] && [ "$2" = "--" ]; then
      shift 2
      exec "$@"
    fi

    printf 'unexpected mise args=%s\\n' "$*" >&2
    exit 1
    """)

    File.chmod!(Path.join(repo_dir, "sym-watch"), 0o755)
    File.chmod!(Path.join(repo_dir, "scripts/mix-runtime"), 0o755)
    File.chmod!(mix_path, 0o755)
    File.chmod!(mise_path, 0o755)
    File.write!(Path.join(repo_dir, "WORKFLOW.md"), "")
    File.write!(Path.join(repo_dir, "mix.exs"), "")

    %{repo_dir: repo_dir, bin_dir: bin_dir}
  end

  defp run_script(script_path, bin_dir, args, opts \\ []) do
    env = [{"PATH", SymphonyElixir.TestSupport.script_path(bin_dir)}] ++ Keyword.get(opts, :env, [])

    System.cmd("/bin/bash", [script_path | args],
      env: env,
      stderr_to_stdout: true
    )
  end
end
