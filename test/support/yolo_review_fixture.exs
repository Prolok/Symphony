defmodule SymphonyElixir.YoloReviewFixture do
  alias SymphonyElixir.Yolo.Scope

  def install(root) do
    git(root, ["init", "--quiet"])
    File.write!(Path.join(root, ".git/info/exclude"), "*\n")
    File.cp_r!("test/fixtures/yolo_review/project/.codex", Path.join(root, ".codex"))
    git(root, ["add", "--force", ".codex"])
    git(root, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "Project acceptance fixture"])
    sha = git(root, ["rev-parse", "HEAD"]) |> String.trim()
    git(root, ["update-ref", "refs/remotes/origin/main", sha])
    path = Path.join(root, "acceptance")
    git(root, ["worktree", "add", "--quiet", "--detach", path, sha])
    %{path: path, sha: sha}
  end

  def evidence do
    %{
      "binding" => Scope.current()["review_contract"]["binding"],
      "checks" => [%{"name" => "CSV fixture comparison", "result" => "passed", "evidence" => "Synthetic fixture input equals expected output"}],
      "findings" => [],
      "limitations" => ["Simulierte Agentenprüfung, keine Live-Abnahme"],
      "decision" => "Prüfbeleg übergeben; Review bleibt menschlich"
    }
  end

  def findings, do: "test/fixtures/yolo_review/findings.json" |> File.read!() |> Jason.decode!()

  def git(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end
end
