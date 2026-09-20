defmodule SymphonyElixir.Yolo.ReviewContract do
  @moduledoc "Versioned project acceptance evidence shared by every PO execution path."
  alias SymphonyElixir.{Config, PathSafety, ProjectContext}
  alias SymphonyElixir.Yolo.{OpenClaw, Operations, Scope, Workspace}

  @skill ".codex/skills/sym-yolo-review/SKILL.md"
  @actions %{
    "regression" => "fix_and_regression_test",
    "test_selection" => "correct_test_selection",
    "reusable_gap" => "fix_and_review_skill_proposal",
    "integration" => "fix_and_integration_test",
    "new_requirement" => "requirement_ticket"
  }

  @spec load(map(), String.t()) :: map()
  def load(%{path: path, sha: sha} = workspace, run_id) do
    context = ProjectContext.current()

    with true <- File.dir?(path),
         true <- Workspace.unchanged?(workspace),
         {:ok, common} <- common_dir(context.root),
         {:ok, ^common} <- common_dir(path),
         {:ok, root} <- PathSafety.canonicalize(path),
         skill_path = Path.join(root, @skill),
         {:ok, ^skill_path} <- PathSafety.canonicalize(skill_path),
         {tree, 0} <- git(path, ["ls-tree", sha, "--", @skill]),
         true <- String.starts_with?(tree, ["100644 blob ", "100755 blob "]),
         {content, 0} <- git(path, ["show", "#{sha}:#{@skill}"]),
         {:ok, ^content} <- File.read(skill_path),
         true <- String.trim(content) != "" do
      %{
        "binding" => %{"version" => 1, "project_id" => context.id, "run_id" => run_id, "workspace" => root, "sha" => sha, "skill_path" => @skill, "skill_sha256" => OpenClaw.digest(content)},
        "content" => content
      }
    else
      _ -> %{"error" => "yolo_review_skill_unavailable_or_unbound"}
    end
  rescue
    _ -> %{"error" => "yolo_review_skill_unavailable_or_unbound"}
  end

  @spec validate(map(), map()) :: :ok | {:error, term()}
  def validate(%{state: "BLOCKER"}, _args), do: :ok

  def validate(issue, %{"review" => review}) when is_map(review) do
    scope = Scope.current()

    with %{"binding" => binding} <- scope["review_contract"],
         true <- review["binding"] == binding,
         %{"binding" => ^binding} <- load(%{path: scope["workspace"], sha: scope["sha"]}, scope["run_id"]),
         true <- valid_result?(review),
         {:ok, operations} <- Operations.related([issue.id]),
         true <- Enum.all?(review["findings"], &linked?(&1, operations, issue.id)) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_review_evidence_invalid}
    end
  end

  def validate(_, _), do: {:error, :yolo_review_evidence_required}

  @spec append_report(String.t(), map()) :: String.t()
  def append_report(report, %{"review" => review}), do: report <> "\n\nPrüf- und Lernbeleg (Vertrag 1):\n```json\n" <> Jason.encode!(review, pretty: true) <> "\n```"
  def append_report(report, _), do: report

  defp valid_result?(review) do
    checks = review["checks"]
    findings = review["findings"]
    limitations = review["limitations"]

    checks != [] and list_of?(checks, &valid_check?/1) and
      list_of?(findings, &valid_finding?/1) and list_of?(limitations, &text?/1) and
      text?(review["decision"]) and
      (Enum.all?(checks, &(&1["result"] == "passed")) or findings != [] or limitations != [])
  end

  defp valid_check?(check) when is_map(check), do: texts?(check, ~w(name evidence)) and check["result"] in ~w(passed failed)
  defp valid_check?(_), do: false

  defp valid_finding?(finding) when is_map(finding) do
    texts?(finding, ~w(reproduction observed expected evidence rationale followup_operation_key)) and
      is_map(finding["prereview"]) and is_boolean(finding["prereview"]["recognizable"]) and text?(finding["prereview"]["reason"]) and
      valid_action?(finding) and valid_proposal?(finding)
  end

  defp valid_finding?(_), do: false

  defp valid_action?(%{"category" => "reusable_gap", "action" => "fix_and_regression_test"}), do: true
  defp valid_action?(finding), do: Map.has_key?(@actions, finding["category"]) and finding["action"] == @actions[finding["category"]]

  defp list_of?(value, check), do: is_list(value) and Enum.all?(value, check)

  defp valid_proposal?(%{"category" => "reusable_gap", "action" => "fix_and_review_skill_proposal", "skill_proposal" => proposal}) when is_map(proposal),
    do: texts?(proposal, ~w(change future_relevance cost benefit))

  defp valid_proposal?(%{"action" => "fix_and_review_skill_proposal"}), do: false
  defp valid_proposal?(finding), do: not Map.has_key?(finding, "skill_proposal")

  defp linked?(finding, operations, id) do
    Enum.any?(operations, fn operation ->
      operation["request"]["operation_key"] == finding["followup_operation_key"] and operation["done"] == true and
        operation["request"]["kind"] == "followup" and id in (operation["request"]["origin_ids"] || [])
    end)
  end

  defp texts?(value, keys), do: Enum.all?(keys, &text?(value[&1]))
  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  defp common_dir(path) do
    case git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      {value, 0} -> PathSafety.canonicalize(String.trim(value))
      _ -> {:error, :not_a_project_checkout}
    end
  end

  defp git(path, args), do: System.cmd("git", args, cd: path, stderr_to_stdout: true, env: Config.without_linear_secret([]))
end
