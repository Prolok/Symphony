ExUnit.start(autorun: false)
Code.require_file("test_support.exs", __DIR__)
Code.require_file("launcher_fixture.ex", __DIR__)

defmodule LauncherFixtureProbe do
  @moduledoc false
  # This subprocess entrypoint must not be discovered by the parent Mix test run.
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use ExUnit.Case
  import SymphonyElixir.LauncherFixture

  @tag timeout: 45_000
  test "fixture survives until its own ExUnit cleanup" do
    [base_dir, owner] = System.argv()

    # Both VMs first encounter the same pre-existing foreign fixture.
    suffix = fn ->
      if Process.put(:candidate_tried, true),
        do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
        else: "foreign"
    end

    fixture = build_script_fixture!(base_dir: base_dir, suffix: suffix)
    paths = [fixture.repo_dir, fixture.home_dir, fixture.bin_dir]

    for path <- paths do
      File.mkdir_p!(path)
      File.write!(Path.join(path, "owner"), owner)
    end

    assert {output, 0} = run_script(fixture.repo_dir, fixture.home_dir, fixture.bin_dir, [])
    assert output =~ "symphony-stub"
    await_service_unlock(fixture.home_dir)
    assert File.read!(Path.join(fixture.repo_dir, ".mix-calls")) == "deps.loadpaths\ncompile\nescript.build\n"
    IO.puts("PROBE ready " <> Base.encode64(:erlang.term_to_binary({System.pid(), fixture})))

    case IO.gets("") do
      "rerun\n" ->
        for path <- paths, do: assert(File.read!(Path.join(path, "owner")) == owner)
        File.write!(Path.join(fixture.repo_dir, "mix.exs"), "# require a new build\n")

        assert {output, 0} =
                 run_script(fixture.repo_dir, fixture.home_dir, fixture.bin_dir, [], env: [{"SYMPHONY_TEST_DEPS_LOADPATHS_STATUS", "1"}])

        assert output =~ "symphony-stub"
        await_service_unlock(fixture.home_dir)

        assert File.read!(Path.join(fixture.repo_dir, ".mix-calls")) ==
                 "deps.loadpaths\ncompile\nescript.build\ndeps.loadpaths\ndeps.get\ncompile\nescript.build\n"

        IO.puts("PROBE reran")
        assert IO.gets("") == "finish\n"

      command ->
        assert command == "finish\n"
    end
  end
end

result = ExUnit.run()
System.halt(if(result.failures == 0, do: 0, else: 1))
