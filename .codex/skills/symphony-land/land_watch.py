#!/usr/bin/env python3
import asyncio
import json
import os
import random
import re
import shutil
from dataclasses import dataclass
from datetime import datetime
from typing import Any

POLL_SECONDS = 10
CHECKS_APPEAR_TIMEOUT_SECONDS = 120
CODEX_BOTS = {
    "chatgpt-codex-connector[bot]",
    "github-actions[bot]",
    "codex-gc-app[bot]",
    "app/codex-gc-app",
}
MAX_GH_RETRIES = 5
BASE_GH_BACKOFF_SECONDS = 2
MANUAL_REVIEW_LABEL = "Requires Manual Review"
SOURCE_REPO_ENV = "SYMPHONY_SOURCE_REPO"
WORKFLOW_DIR_ENV = "SYMPHONY_WORKFLOW_DIR"
WORKFLOW_FILE_ENV = "SYMPHONY_WORKFLOW_FILE"
ISSUE_IDENTIFIER_ENV = "SYMPHONY_ISSUE_IDENTIFIER"
MANUAL_REVIEW_LABEL_ENV = "SYMPHONY_ISSUE_LABELS_JSON"
MANUAL_REVIEW_BLOCKER_EXIT = 7
APP_LABEL_LOOKUP_EXIT = 8
DECISIVE_REVIEW_STATES = {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}


@dataclass
class PrInfo:
    number: int
    url: str
    head_sha: str
    mergeable: str | None
    merge_state: str | None
    author_login: str | None = None


@dataclass
class CheckSummary:
    pending: bool
    failed: bool
    failures: list[str]
    accepted_counts: dict[str, int]


@dataclass
class MergePreflightEvidence:
    branch: str
    local_head: str
    remote_branch_exists: bool
    pr: PrInfo | None


class RateLimitError(RuntimeError):
    pass


class PrNotFoundError(RuntimeError):
    pass


class LabelRefreshError(RuntimeError):
    pass


class AppLabelLookupRequired(LabelRefreshError):
    pass


def is_rate_limit_error(error: str) -> bool:
    return "HTTP 429" in error or "rate limit" in error.lower()


def is_pr_not_found_error(error: str) -> bool:
    normalized = error.lower()
    return (
        "no open pull requests found" in normalized
        or "no pull requests found" in normalized
        or "no pull request found" in normalized
        or "could not find any pull requests" in normalized
    )


async def run_git(*args: str) -> str:
    proc = await asyncio.create_subprocess_exec(
        "git",
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    if proc.returncode == 0:
        return stdout.decode()
    error = stderr.decode().strip() or stdout.decode().strip() or "git command failed"
    raise RuntimeError(error)


async def run_gh(*args: str) -> str:
    max_delay = BASE_GH_BACKOFF_SECONDS * (2 ** (MAX_GH_RETRIES - 1))
    delay_seconds = BASE_GH_BACKOFF_SECONDS
    last_error = "gh command failed"
    for attempt in range(1, MAX_GH_RETRIES + 1):
        proc = await asyncio.create_subprocess_exec(
            "gh",
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode == 0:
            return stdout.decode()
        error = stderr.decode().strip() or "gh command failed"
        if not is_rate_limit_error(error):
            raise RuntimeError(error)
        last_error = error
        if attempt >= MAX_GH_RETRIES:
            break
        jitter = random.uniform(0, delay_seconds)
        await asyncio.sleep(min(delay_seconds + jitter, max_delay))
        delay_seconds = min(delay_seconds * 2, max_delay)
    raise RateLimitError(last_error)


async def get_pr_info(branch: str | None = None) -> PrInfo:
    args = ["pr", "view"]
    if branch is not None:
        args.append(branch)
    args.extend(
        [
            "--json",
            "number,url,headRefOid,mergeable,mergeStateStatus,author",
        ],
    )
    try:
        data = await run_gh(*args)
    except RuntimeError as exc:
        error = str(exc)
        if is_pr_not_found_error(error):
            raise PrNotFoundError(error) from exc
        raise
    parsed = json.loads(data)
    author = parsed.get("author") or {}
    return PrInfo(
        number=parsed["number"],
        url=parsed["url"],
        head_sha=parsed["headRefOid"],
        mergeable=parsed.get("mergeable"),
        merge_state=parsed.get("mergeStateStatus"),
        author_login=author.get("login"),
    )


async def get_paginated_list(endpoint: str) -> list[dict[str, Any]]:
    page = 1
    items: list[dict[str, Any]] = []
    while True:
        data = await run_gh(
            "api",
            "--method",
            "GET",
            endpoint,
            "-f",
            "per_page=100",
            "-f",
            f"page={page}",
        )
        batch = json.loads(data)
        if not batch:
            break
        items.extend(batch)
        page += 1
    return items


async def get_issue_comments(pr_number: int) -> list[dict[str, Any]]:
    return await get_paginated_list(
        f"repos/{{owner}}/{{repo}}/issues/{pr_number}/comments",
    )


async def get_review_comments(pr_number: int) -> list[dict[str, Any]]:
    return await get_paginated_list(
        f"repos/{{owner}}/{{repo}}/pulls/{pr_number}/comments",
    )


async def get_reviews(pr_number: int) -> list[dict[str, Any]]:
    page = 1
    reviews: list[dict[str, Any]] = []
    while True:
        data = await run_gh(
            "api",
            "--method",
            "GET",
            f"repos/{{owner}}/{{repo}}/pulls/{pr_number}/reviews",
            "-f",
            "per_page=100",
            "-f",
            f"page={page}",
        )
        batch = json.loads(data)
        if not batch:
            break
        reviews.extend(batch)
        page += 1
    return reviews


async def get_check_runs(head_sha: str) -> list[dict[str, Any]]:
    page = 1
    check_runs: list[dict[str, Any]] = []
    while True:
        data = await run_gh(
            "api",
            "--method",
            "GET",
            f"repos/{{owner}}/{{repo}}/commits/{head_sha}/check-runs",
            "-f",
            "per_page=100",
            "-f",
            f"page={page}",
        )
        payload = json.loads(data)
        batch = payload.get("check_runs", [])
        if not batch:
            break
        check_runs.extend(batch)
        total_count = payload.get("total_count")
        if total_count is not None and len(check_runs) >= total_count:
            break
        page += 1
    return check_runs


def parse_time(value: str) -> datetime:
    normalized = value.replace("Z", "+00:00")
    return datetime.fromisoformat(normalized)


CONTROL_CHARS_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")


def sanitize_terminal_output(value: str) -> str:
    return CONTROL_CHARS_RE.sub("", value)


def check_timestamp(check: dict[str, Any]) -> datetime | None:
    for key in ("completed_at", "started_at", "run_started_at", "created_at"):
        value = check.get(key)
        if value:
            return parse_time(value)
    return None


def dedupe_check_runs(check_runs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    latest_by_name: dict[str, dict[str, Any]] = {}
    for check in check_runs:
        name = check.get("name", "unknown")
        timestamp = check_timestamp(check)
        if name not in latest_by_name:
            latest_by_name[name] = check
            continue
        existing = latest_by_name[name]
        existing_timestamp = check_timestamp(existing)
        if timestamp is None:
            continue
        if existing_timestamp is None or timestamp > existing_timestamp:
            latest_by_name[name] = check
    return list(latest_by_name.values())


def summarize_checks(check_runs: list[dict[str, Any]]) -> CheckSummary:
    if not check_runs:
        return CheckSummary(
            pending=True,
            failed=False,
            failures=["no checks reported"],
            accepted_counts={},
        )
    check_runs = dedupe_check_runs(check_runs)
    pending = False
    failed = False
    failures: list[str] = []
    accepted_counts = {"success": 0, "skipped": 0, "neutral": 0}
    for check in check_runs:
        status = check.get("status")
        conclusion = check.get("conclusion")
        name = check.get("name", "unknown")
        if status != "completed":
            pending = True
            continue
        if conclusion in accepted_counts:
            accepted_counts[conclusion] += 1
            continue
        if conclusion is None:
            conclusion = "missing conclusion"
        else:
            conclusion = str(conclusion)
        failed = True
        failures.append(f"{name}: {conclusion}")
    return CheckSummary(
        pending=pending,
        failed=failed,
        failures=failures,
        accepted_counts=accepted_counts,
    )


def check_summary_message(summary: CheckSummary) -> str:
    success = summary.accepted_counts.get("success", 0)
    skipped = summary.accepted_counts.get("skipped", 0)
    neutral = summary.accepted_counts.get("neutral", 0)
    parts: list[str] = []
    if success:
        parts.append(f"{success} success")
    if skipped:
        parts.append(f"{skipped} skipped by policy")
    if neutral:
        parts.append(f"{neutral} neutral accepted")
    if skipped or neutral:
        return f"GitHub checks acceptable: {', '.join(parts)}"
    if success:
        return f"GitHub checks passed: {', '.join(parts)}"
    return "GitHub checks acceptable: no completed checks reported"


async def current_branch() -> str:
    return (await run_git("branch", "--show-current")).strip()


async def local_head_sha() -> str:
    return (await run_git("rev-parse", "HEAD")).strip()


async def remote_branch_exists(branch: str) -> bool:
    proc = await asyncio.create_subprocess_exec(
        "git",
        "ls-remote",
        "--exit-code",
        "--heads",
        "origin",
        branch,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    if proc.returncode == 0:
        return True
    if proc.returncode == 2:
        return False
    error = stderr.decode().strip() or stdout.decode().strip() or "git ls-remote failed"
    raise RuntimeError(error)


def symphony_issue_branch(branch: str) -> bool:
    return re.fullmatch(r"symphony/[A-Z][A-Z0-9]*-\d+", branch) is not None


def short_sha(value: str) -> str:
    return value[:12]


def merge_preflight_failures(evidence: MergePreflightEvidence) -> list[str]:
    failures: list[str] = []
    if not symphony_issue_branch(evidence.branch):
        failures.append(
            f"Current branch must be symphony/<Issue>; got {evidence.branch or '<detached>'}",
        )
    if not evidence.remote_branch_exists:
        failures.append(
            f"Remote branch origin/{evidence.branch} is missing; run symphony-push from a clean, locally validated Test (AI) handoff before merge",
        )
    if evidence.pr is None:
        failures.append(
            "No open GitHub PR found for the current branch; run symphony-push to create or update it before merge",
        )
    elif evidence.pr.head_sha != evidence.local_head:
        failures.append(
            "PR head mismatch: "
            f"local HEAD {short_sha(evidence.local_head)} != PR head {short_sha(evidence.pr.head_sha)}; "
            "publish the current branch and rerun land_watch",
        )
    return failures


async def collect_merge_preflight_evidence() -> MergePreflightEvidence:
    branch = await current_branch()
    local_head = await local_head_sha()
    remote_exists = await remote_branch_exists(branch) if branch else False
    pr = None
    if remote_exists:
        try:
            pr = await get_pr_info(branch)
        except PrNotFoundError:
            pr = None
    return MergePreflightEvidence(
        branch=branch,
        local_head=local_head,
        remote_branch_exists=remote_exists,
        pr=pr,
    )


async def require_merge_preflight() -> MergePreflightEvidence:
    evidence = await collect_merge_preflight_evidence()
    failures = merge_preflight_failures(evidence)
    if failures:
        print("Merge preflight failed:")
        for failure in failures:
            print(f"- {failure}")
        raise SystemExit(6)
    if evidence.pr is None:
        raise RuntimeError("merge preflight did not load PR information")
    return evidence


def latest_review_request_at(comments: list[dict[str, Any]]) -> datetime | None:
    latest: datetime | None = None
    for comment in comments:
        if is_codex_bot_user(comment.get("user", {})):
            continue
        body = comment.get("body") or ""
        if "@codex review" not in body:
            continue
        timestamp = comment_time(comment)
        if timestamp is None:
            continue
        if latest is None or timestamp > latest:
            latest = timestamp
    return latest


def filter_codex_comments(
    comments: list[dict[str, Any]],
    review_requested_at: datetime | None,
) -> list[dict[str, Any]]:
    latest_codex_reply = latest_codex_reply_by_thread(comments)
    latest_issue_ack = latest_codex_issue_reply_time(comments)
    codex_comments = [c for c in comments if is_codex_bot_user(c.get("user", {}))]
    filtered: list[dict[str, Any]] = []
    for comment in codex_comments:
        created_time = comment_time(comment)
        if created_time is None:
            continue
        if review_requested_at is not None and created_time <= review_requested_at:
            continue
        is_threaded = bool(
            comment.get("in_reply_to_id") or comment.get("pull_request_review_id")
        )
        if not is_threaded:
            if latest_issue_ack is not None and created_time <= latest_issue_ack:
                continue
        else:
            thread_root = thread_root_id(comment)
            last_reply = None
            if thread_root is not None:
                last_reply = latest_codex_reply.get(thread_root)
            if last_reply and last_reply > created_time:
                continue
        filtered.append(comment)
    return filtered


def is_codex_bot_user(user: dict[str, Any]) -> bool:
    login = user.get("login") or ""
    return login in CODEX_BOTS


def is_bot_user(user: dict[str, Any]) -> bool:
    login = user.get("login") or ""
    if is_codex_bot_user(user):
        return True
    if user.get("type") == "Bot":
        return True
    return login.endswith("[bot]")


def issue_labels_from_env(value: str | None = None) -> list[str]:
    raw = os.environ.get(MANUAL_REVIEW_LABEL_ENV, "[]") if value is None else value
    return issue_labels_from_json(raw) or []


def issue_labels_from_json(raw: str | None) -> list[str] | None:
    if not raw:
        return []
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, list):
        return None
    return [label for label in parsed if isinstance(label, str)]


async def current_issue_labels(snapshot_labels: list[str] | None = None) -> list[str]:
    require_legacy_label_refresh()
    snapshot = issue_labels_from_env() if snapshot_labels is None else snapshot_labels
    if current_issue_identifier() is None:
        return snapshot
    live_labels = await fetch_current_issue_labels()
    if live_labels is None:
        raise LabelRefreshError("Could not refresh current Linear issue labels before merge.")
    return live_labels


def require_legacy_label_refresh() -> None:
    if os.environ.get("SYMPHONY_LINEAR_AUTH_MODE") == "app":
        if current_issue_identifier() is None:
            raise LabelRefreshError("Missing issue identity for the App label gate.")
        raise AppLabelLookupRequired("Live labels must be read through the bound Linear tool.")


def current_issue_identifier() -> str | None:
    issue_identifier = os.environ.get(ISSUE_IDENTIFIER_ENV)
    if issue_identifier is None or not issue_identifier.strip():
        return None
    return issue_identifier


async def fetch_current_issue_labels() -> list[str] | None:
    if current_issue_identifier() is None:
        return None
    try:
        output = await run_tracker_label_refresh()
    except RuntimeError as error:
        raise LabelRefreshError(
            "Could not refresh current Linear issue labels before merge: "
            f"{error}",
        ) from error
    labels = issue_labels_from_refresh_output(output)
    if labels is None:
        raise LabelRefreshError(
            "Could not parse refreshed Linear issue labels before merge.",
        )
    return labels


def issue_labels_from_refresh_output(output: str) -> list[str] | None:
    for line in reversed(output.splitlines()):
        labels = issue_labels_from_json(line.strip())
        if labels is not None:
            return labels
    return None


async def run_tracker_label_refresh() -> str:
    require_legacy_label_refresh()
    source_root = await source_repo_root()
    workflow_root = await workflow_execution_root()
    elixir = """
issue_identifier = System.fetch_env!("SYMPHONY_ISSUE_IDENTIFIER")

case System.get_env("SYMPHONY_WORKFLOW_FILE") do
  value when is_binary(value) ->
    case String.trim(value) do
      "" -> :ok
      workflow_file -> SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)
    end

  _ ->
    :ok
end

repo_root =
  case System.get_env("SYMPHONY_SOURCE_REPO") do
    value when is_binary(value) ->
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end

    _ ->
      nil
  end ||
    System.cmd("git", ["rev-parse", "--show-toplevel"])
    |> elem(0)
    |> String.trim()

:ok = SymphonyElixir.EnvFile.load(SymphonyElixir.EnvFile.config_dir(repo_root), override_existing: true)
{:ok, _} = Application.ensure_all_started(:req)

case SymphonyElixir.Tracker.fetch_issue_by_identifier(issue_identifier) do
  {:ok, issue} ->
    IO.puts(Jason.encode!(Map.get(issue, :labels, [])))

  {:error, reason} ->
    IO.warn("failed to refresh Linear issue labels: #{inspect(reason)}")
    System.halt(1)
end
"""
    command = (
        ["mise", "exec", "--", "mix", "run", "--no-start", "-e", elixir]
        if shutil.which("mise")
        else ["mix", "run", "--no-start", "-e", elixir]
    )
    child_env = os.environ.copy()
    child_env[SOURCE_REPO_ENV] = source_root
    proc = await asyncio.create_subprocess_exec(
        *command,
        cwd=workflow_root,
        env=child_env,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    if proc.returncode == 0:
        return stdout.decode()
    error = stderr.decode().strip() or stdout.decode().strip() or "label refresh failed"
    raise RuntimeError(error)


async def source_repo_root() -> str:
    source_repo = os.environ.get(SOURCE_REPO_ENV)
    if source_repo is not None and source_repo.strip():
        return source_repo.strip()
    return (await run_git("rev-parse", "--show-toplevel")).strip()


async def workflow_execution_root() -> str:
    workflow_dir = os.environ.get(WORKFLOW_DIR_ENV)
    workflow_root = (
        workflow_dir.strip()
        if workflow_dir is not None and workflow_dir.strip()
        else (await run_git("rev-parse", "--show-toplevel")).strip()
    )
    if not os.path.isfile(os.path.join(workflow_root, "mix.exs")):
        raise RuntimeError(
            "Could not find a Symphony Mix project for label refresh at "
            f"{workflow_root}",
        )
    return workflow_root


def normalize_label_name(label: str) -> str:
    return label.strip().lower()


def requires_manual_review(labels: list[str]) -> bool:
    canonical = normalize_label_name(MANUAL_REVIEW_LABEL)
    return any(normalize_label_name(label) == canonical for label in labels)


def is_codex_reply_body(body: str) -> bool:
    return body.startswith("[codex]")


def is_codex_review_body(body: str) -> bool:
    return body.startswith("## Codex Review")


def latest_codex_issue_reply_time(
    comments: list[dict[str, Any]],
) -> datetime | None:
    latest: datetime | None = None
    for comment in comments:
        body = (comment.get("body") or "").strip()
        if not is_codex_reply_body(body):
            continue
        created_time = comment_time(comment)
        if created_time is None:
            continue
        if latest is None or created_time > latest:
            latest = created_time
    return latest


def filter_human_issue_comments(comments: list[dict[str, Any]]) -> list[dict[str, Any]]:
    latest_ack = latest_codex_issue_reply_time(comments)
    filtered: list[dict[str, Any]] = []
    for comment in comments:
        if is_bot_user(comment.get("user", {})):
            continue
        body = (comment.get("body") or "").strip()
        if is_codex_reply_body(body):
            continue
        if is_codex_review_body(body):
            continue
        if "@codex review" in body:
            continue
        created_time = comment_time(comment)
        if (
            latest_ack is not None
            and created_time is not None
            and created_time <= latest_ack
        ):
            continue
        filtered.append(comment)
    return filtered


def filter_codex_review_issue_comments(
    comments: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    latest_ack = latest_codex_issue_reply_time(comments)
    filtered: list[dict[str, Any]] = []
    for comment in comments:
        body = (comment.get("body") or "").strip()
        if not is_codex_review_body(body):
            continue
        created_time = comment_time(comment)
        if (
            latest_ack is not None
            and created_time is not None
            and created_time <= latest_ack
        ):
            continue
        filtered.append(comment)
    return filtered


def thread_root_id(comment: dict[str, Any]) -> int | None:
    return comment.get("in_reply_to_id") or comment.get("id")


def comment_time(comment: dict[str, Any]) -> datetime | None:
    timestamp = comment.get("updated_at") or comment.get("created_at")
    if not timestamp:
        return None
    return parse_time(timestamp)


def latest_codex_reply_by_thread(
    comments: list[dict[str, Any]],
) -> dict[int, datetime]:
    latest: dict[int, datetime] = {}
    for comment in comments:
        body = (comment.get("body") or "").strip()
        if not is_codex_reply_body(body):
            continue
        thread_root = thread_root_id(comment)
        created_time = comment_time(comment)
        if thread_root is None or created_time is None:
            continue
        existing = latest.get(thread_root)
        if existing is None or created_time > existing:
            latest[thread_root] = created_time
    return latest


def filter_human_review_comments(
    comments: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    latest_codex_reply = latest_codex_reply_by_thread(comments)
    filtered: list[dict[str, Any]] = []
    for comment in comments:
        if is_bot_user(comment.get("user", {})):
            continue
        body = (comment.get("body") or "").strip()
        if is_codex_reply_body(body):
            continue
        thread_root = thread_root_id(comment)
        created_time = comment_time(comment)
        last_codex_reply = None
        if thread_root is not None:
            last_codex_reply = latest_codex_reply.get(thread_root)
        if last_codex_reply and created_time and created_time <= last_codex_reply:
            continue
        filtered.append(comment)
    return filtered


def is_blocking_review(
    review: dict[str, Any],
    review_requested_at: datetime | None,
) -> bool:
    created_at = review.get("submitted_at") or review.get("created_at")
    if not created_at:
        return False
    user_login = review.get("user", {}).get("login")
    created_time = parse_time(created_at)
    if (
        user_login in CODEX_BOTS
        and review_requested_at is not None
        and created_time <= review_requested_at
    ):
        return False
    body = (review.get("body") or "").strip()
    state = review.get("state")
    if user_login in CODEX_BOTS:
        return state == "CHANGES_REQUESTED"
    if body.startswith("[codex]") or state in ("APPROVED", "DISMISSED"):
        return False
    blocking = False
    if body or state == "CHANGES_REQUESTED":
        blocking = True
    elif state == "COMMENTED":
        blocking = False
    elif state:
        blocking = state not in ("APPROVED", "DISMISSED")
    return blocking


def review_timestamp(review: dict[str, Any]) -> datetime | None:
    created_at = review.get("submitted_at") or review.get("created_at")
    if not created_at:
        return None
    return parse_time(created_at)


def dedupe_reviews(reviews: list[dict[str, Any]]) -> list[dict[str, Any]]:
    latest_by_user: dict[str, dict[str, Any]] = {}
    for review in reviews:
        user_login = review.get("user", {}).get("login")
        if not user_login:
            continue
        timestamp = review_timestamp(review)
        if user_login not in latest_by_user:
            latest_by_user[user_login] = review
            continue
        existing = latest_by_user[user_login]
        existing_timestamp = review_timestamp(existing)
        if timestamp is None:
            continue
        if existing_timestamp is None or timestamp > existing_timestamp:
            latest_by_user[user_login] = review
    return list(latest_by_user.values())


def latest_decisive_reviews(reviews: list[dict[str, Any]]) -> list[dict[str, Any]]:
    latest_by_user: dict[str, dict[str, Any]] = {}
    for review in reviews:
        state = review_state(review)
        if state not in DECISIVE_REVIEW_STATES:
            continue
        user_login = review.get("user", {}).get("login")
        if not user_login:
            continue
        user_key = user_login.lower()
        timestamp = review_timestamp(review)
        if user_key not in latest_by_user:
            latest_by_user[user_key] = review
            continue
        existing = latest_by_user[user_key]
        existing_timestamp = review_timestamp(existing)
        if timestamp is None:
            continue
        if existing_timestamp is None or timestamp > existing_timestamp:
            latest_by_user[user_key] = review
    return list(latest_by_user.values())


def review_state(review: dict[str, Any]) -> str | None:
    state = review.get("state")
    return state.upper() if isinstance(state, str) else None


def same_login(left: str | None, right: str | None) -> bool:
    if not left or not right:
        return False
    return left.lower() == right.lower()


def is_valid_manual_approval_review(
    review: dict[str, Any],
    head_sha: str,
    author_login: str | None,
) -> bool:
    user = review.get("user", {})
    reviewer_login = user.get("login")
    return (
        review_state(review) == "APPROVED"
        and isinstance(reviewer_login, str)
        and reviewer_login != ""
        and not is_bot_user(user)
        and not same_login(reviewer_login, author_login)
        and review.get("commit_id") == head_sha
    )


def has_valid_manual_approval(
    reviews: list[dict[str, Any]],
    head_sha: str,
    author_login: str | None,
) -> bool:
    return any(
        is_valid_manual_approval_review(review, head_sha, author_login)
        for review in latest_decisive_reviews(reviews)
    )


def manual_review_blocker_message(pr: PrInfo) -> str:
    return (
        "Manual GitHub approval required before merge. "
        f"PR #{pr.number}: {pr.url}; current head SHA: {pr.head_sha}; "
        f"Linear label `{MANUAL_REVIEW_LABEL}` is set. "
        "Ask a human GitHub reviewer other than the PR author to review and "
        "approve the current PR head, then move the Linear issue back to `Merge (AI)`."
    )


def label_refresh_blocker_message(pr: PrInfo, error: LabelRefreshError) -> str:
    return (
        "Could not verify current Linear labels before merge. "
        f"PR #{pr.number}: {pr.url}; current head SHA: {pr.head_sha}; "
        f"unable to determine whether Linear label `{MANUAL_REVIEW_LABEL}` is set. "
        f"{error} Restore Linear label lookup, then move the Linear issue back to `Merge (AI)`."
    )


def raise_on_missing_manual_review_approval(
    labels: list[str],
    pr: PrInfo,
    reviews: list[dict[str, Any]],
) -> None:
    if not requires_manual_review(labels):
        return
    if has_valid_manual_approval(reviews, pr.head_sha, pr.author_login):
        print(
            f"Manual GitHub approval gate passed for PR #{pr.number} at {short_sha(pr.head_sha)}.",
        )
        return
    print(manual_review_blocker_message(pr))
    raise SystemExit(MANUAL_REVIEW_BLOCKER_EXIT)


def filter_blocking_reviews(
    reviews: list[dict[str, Any]],
    review_requested_at: datetime | None,
) -> list[dict[str, Any]]:
    return [
        review
        for review in dedupe_reviews(reviews)
        if is_blocking_review(review, review_requested_at)
    ]


def is_merge_conflicting(pr: PrInfo) -> bool:
    return pr.mergeable == "CONFLICTING" or pr.merge_state == "DIRTY"


async def fetch_review_context(
    pr_number: int,
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[dict[str, Any]],
    datetime | None,
]:
    issue_comments = await get_issue_comments(pr_number)
    review_request_at = latest_review_request_at(issue_comments)
    review_comments = await get_review_comments(pr_number)
    reviews = await get_reviews(pr_number)
    return issue_comments, review_comments, reviews, review_request_at


def raise_on_human_feedback(
    issue_comments: list[dict[str, Any]],
    review_comments: list[dict[str, Any]],
    reviews: list[dict[str, Any]],
    review_request_at: datetime | None,
) -> None:
    human_issue_comments = filter_human_issue_comments(issue_comments)
    codex_review_comments = filter_codex_review_issue_comments(issue_comments)
    human_review_comments = filter_human_review_comments(review_comments)
    if human_issue_comments or human_review_comments or codex_review_comments:
        print("Review comments detected. Address before merge.")
        print(
            "Reminder: decide whether feedback stays in scope; defer if needed "
            "and note in your root-level update.",
        )
        raise SystemExit(2)
    blocking_reviews = filter_blocking_reviews(reviews, review_request_at)
    if blocking_reviews:
        print("Review states/comments detected. Address before merge.")
        print(
            "Reminder: keep PR title/description aligned with the full scope "
            "when changes expand.",
        )
        raise SystemExit(2)


async def wait_for_codex(pr_number: int, checks_done: asyncio.Event) -> None:
    print("Waiting for review feedback...", flush=True)
    while True:
        (
            issue_comments,
            review_comments,
            reviews,
            review_request_at,
        ) = await fetch_review_context(pr_number)
        bot_issue_comments = filter_codex_comments(issue_comments, review_request_at)
        bot_review_comments = filter_codex_comments(review_comments, review_request_at)
        bot_comments = bot_issue_comments + bot_review_comments
        raise_on_human_feedback(
            issue_comments,
            review_comments,
            reviews,
            review_request_at,
        )
        if bot_comments:
            latest = max(
                bot_comments,
                key=lambda comment: parse_time(comment["created_at"]),
            )
            body = sanitize_terminal_output(latest.get("body") or "").strip()
            if body:
                print("Codex left comments. Address feedback before merge.")
                print(body)
                raise SystemExit(2)
        if checks_done.is_set():
            return
        await asyncio.sleep(POLL_SECONDS)


async def wait_for_checks(head_sha: str, checks_done: asyncio.Event) -> None:
    print("Waiting for CI checks...", flush=True)
    empty_seconds = 0
    while True:
        check_runs = await get_check_runs(head_sha)
        if not check_runs:
            empty_seconds += POLL_SECONDS
            if empty_seconds >= CHECKS_APPEAR_TIMEOUT_SECONDS:
                print(
                    "No checks detected after 120s; check CI configuration",
                )
                raise SystemExit(3)
            await asyncio.sleep(POLL_SECONDS)
            continue
        empty_seconds = 0
        summary = summarize_checks(check_runs)
        if summary.failed:
            print("Checks failed:")
            for failure in summary.failures:
                print(f"- {failure}")
            raise SystemExit(3)
        if not summary.pending:
            print(check_summary_message(summary))
            checks_done.set()
            return
        await asyncio.sleep(POLL_SECONDS)


async def watch_pr() -> None:
    evidence = await require_merge_preflight()
    pr = evidence.pr
    branch = evidence.branch
    if is_merge_conflicting(pr):
        print(
            "PR has merge conflicts. Resolve/rebase against main and push before "
            "running land_watch again.",
        )
        raise SystemExit(5)
    head_sha = pr.head_sha
    checks_done = asyncio.Event()
    codex_task = asyncio.create_task(wait_for_codex(pr.number, checks_done))
    checks_task = asyncio.create_task(wait_for_checks(head_sha, checks_done))

    async def head_monitor() -> None:
        while True:
            current = await get_pr_info(branch)
            if is_merge_conflicting(current):
                print(
                    "PR has merge conflicts. Resolve/rebase against main and push "
                    "before running land_watch again.",
                )
                raise SystemExit(5)
            if current.head_sha != head_sha:
                print("PR head updated; pull/amend/force-push to retrigger CI")
                raise SystemExit(4)
            await asyncio.sleep(POLL_SECONDS)

    monitor_task = asyncio.create_task(head_monitor())
    success_task = asyncio.gather(codex_task, checks_task)

    done, pending = await asyncio.wait(
        [monitor_task, success_task],
        return_when=asyncio.FIRST_COMPLETED,
    )
    for task in pending:
        task.cancel()
    for task in done:
        exc = task.exception()
        if exc:
            raise exc

    try:
        labels = await current_issue_labels()
    except AppLabelLookupRequired:
        print(
            f"Merge gate incomplete: {pr.url}, head {head_sha}, issue {current_issue_identifier()}. "
            "GitHub checks/review completed. Read current issue labels through the bound Linear tool; "
            "then complete the manual-approval gate and recheck the PR head before merging. "
            "Do not use the dispatch snapshot or a shell/Mix credential fallback."
        )
        raise SystemExit(APP_LABEL_LOOKUP_EXIT) from None
    except LabelRefreshError as error:
        print(label_refresh_blocker_message(pr, error))
        raise SystemExit(MANUAL_REVIEW_BLOCKER_EXIT) from error
    if requires_manual_review(labels):
        current = await get_pr_info(branch)
        if is_merge_conflicting(current):
            print(
                "PR has merge conflicts. Resolve/rebase against main and push "
                "before running land_watch again.",
            )
            raise SystemExit(5)
        if current.head_sha != head_sha:
            print("PR head updated; pull/amend/force-push to retrigger CI")
            raise SystemExit(4)
        (
            issue_comments,
            review_comments,
            reviews,
            review_request_at,
        ) = await fetch_review_context(current.number)
        raise_on_human_feedback(
            issue_comments,
            review_comments,
            reviews,
            review_request_at,
        )
        raise_on_missing_manual_review_approval(labels, current, reviews)


if __name__ == "__main__":
    try:
        asyncio.run(watch_pr())
    except SystemExit as exc:
        raise SystemExit(exc.code) from None
