defmodule SymphonyElixir.IssueLeaseTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Linear.IssueLease

  setup do
    root = Path.join(System.tmp_dir!(), "lease-#{System.unique_integer([:positive])}")
    helper_dir = Path.join(root, "priv/linear_app")
    File.mkdir_p!(helper_dir)
    File.write!(Path.join(root, ".symphony-release.json"), "{}")
    File.cp!("priv/linear_app/issue_lease.py", Path.join(helper_dir, "issue_lease.py"))
    source = File.read!("priv/linear_app/state_lock.py")

    File.write!(
      Path.join(helper_dir, "state_lock.py"),
      source <> "\noriginal_lock = state_lock\ndef state_lock(a, b, timeout=10):\n    return original_lock(a, b, timeout=timeout, root=" <> Jason.encode!(root) <> ")\n"
    )

    System.put_env("SYMPHONY_RELEASE_ROOT", root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, helper_dir: helper_dir}
  end

  test "host-wide issue lease excludes a second owner and releases on process death" do
    parent = self()

    first =
      Task.async(fn ->
        IssueLease.with_lock("workspace", "issue", fn ->
          send(parent, :owned)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :owned
    assert {:error, :issue_already_owned} = IssueLease.with_lock("workspace", "issue", fn -> flunk("double owner") end)
    assert :ok = IssueLease.with_lock("workspace", "other", fn -> :ok end)
    Task.shutdown(first, :brutal_kill)
    assert :ok = IssueLease.with_lock("workspace", "issue", fn -> :ok end)
  end

  test "in-memory fixtures run without a Linear issue lease" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert :memory = IssueLease.run(%Issue{id: "issue"}, fn -> :memory end)
  end

  test "helper backend failure is unavailable, never a competing issue owner", %{helper_dir: helper_dir} do
    File.write!(Path.join(helper_dir, "state_lock.py"), "def state_lock(*args, **kwargs):\n    raise OSError('synthetic backend failure')\nclass StateLockError(Exception):\n    pass\n")
    assert {:error, :issue_lease_unavailable} = IssueLease.with_lock("workspace", "issue", fn -> flunk("no lease") end)
    assert {:error, :comment_journal_unavailable} = IssueLease.with_journal_lock("project", fn -> flunk("no journal") end)
  end

  @tag timeout: 20_000
  test "missing executable and unresponsive helper fail visibly", %{root: root, helper_dir: helper_dir} do
    previous = System.get_env("PATH")

    try do
      System.put_env("PATH", root)
      assert {:error, :issue_lease_unavailable} = IssueLease.with_lock("workspace", "issue", fn -> flunk("no lease") end)
    after
      System.put_env("PATH", previous)
    end

    File.write!(Path.join(helper_dir, "issue_lease.py"), "import time\ntime.sleep(20)\n")
    assert {:error, :issue_lease_unavailable} = IssueLease.with_lock("workspace", "issue", fn -> flunk("no lease") end)
  end
end
