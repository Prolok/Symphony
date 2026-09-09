ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)

tmpdir_snapshot = System.get_env("TMPDIR")
# macOS exposes /var through /private/var. Fixtures compare physical cwd and
# symlink targets, so give them the same canonical temp root as the scripts.
{physical_tmpdir, 0} = System.cmd("/bin/pwd", ["-P"], cd: System.tmp_dir!())
System.put_env("TMPDIR", String.trim(physical_tmpdir))
symphony_runtime_env_snapshot = SymphonyElixir.TestSupport.scrub_symphony_runtime_env()
git_ceiling_snapshot = System.get_env("GIT_CEILING_DIRECTORIES")
# Keep non-Git fixtures isolated even when TMPDIR lives inside a worktree.
System.put_env("GIT_CEILING_DIRECTORIES", System.tmp_dir!())

ExUnit.after_suite(fn _result ->
  SymphonyElixir.TestSupport.restore_env_snapshot(symphony_runtime_env_snapshot)
  SymphonyElixir.TestSupport.restore_env("GIT_CEILING_DIRECTORIES", git_ceiling_snapshot)
  SymphonyElixir.TestSupport.restore_env("TMPDIR", tmpdir_snapshot)
end)
