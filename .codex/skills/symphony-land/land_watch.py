#!/usr/bin/env python3
import asyncio
import json
import os
import random
import re
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import Any
from urllib.parse import quote

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
COMMENT_CHECKPOINT_EXIT = 9
BOUND_REQUEST = "SYMPHONY_BOUND_REQUEST "
bound_request = None
DECISIVE_REVIEW_STATES = {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}


@dataclass
class PrInfo:
    number: int
    url: str
    head_sha: str
    mergeable: str | None
    merge_state: str | None
    author_login: str | None = None
    base_branch: str | None = None
    base_sha: str | None = None
    state: str = "OPEN"


@dataclass
class CheckSummary:
    pending: bool
    failed: bool
    failures: list[str]
    accepted_counts: dict[str, int]
    no_ci: bool = False


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
    env = os.environ.copy()
    if not env.get("GH_REPO"):
        env["GH_REPO"] = (await run_git("remote", "get-url", "origin")).strip()
    # A merge retry must re-enter merge_bound and its fresh runtime gates.
    # Read-only GitHub calls may keep their bounded rate-limit backoff.
    attempts = 1 if args[:2] == ("pr", "merge") else MAX_GH_RETRIES
    max_delay = BASE_GH_BACKOFF_SECONDS * (2 ** (MAX_GH_RETRIES - 1))
    delay_seconds = BASE_GH_BACKOFF_SECONDS
    last_error = "gh command failed"
    for attempt in range(1, attempts + 1):
        proc = await asyncio.create_subprocess_exec(
            "gh",
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode == 0:
            return stdout.decode()
        error = stderr.decode().strip() or "gh command failed"
        if not is_rate_limit_error(error):
            raise RuntimeError(error)
        last_error = error
        if attempt >= attempts:
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
            "number,url,headRefOid,baseRefName,baseRefOid,state,mergeable,mergeStateStatus,author",
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
        base_branch=parsed["baseRefName"],
        base_sha=parsed["baseRefOid"],
        state=parsed["state"],
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
    runs = await ci_pages(f"commits/{head_sha}/check-runs", "check_runs")
    for run in runs:
        ci_require(run.get("head_sha") == head_sha, "check head mismatch")
        ci_require(isinstance(run.get("name"), str) and run["name"], "check name missing")
        ci_require(run.get("status") in {"queued", "in_progress", "completed", "waiting", "pending", "requested"}, "unknown check status")
        ci_require(isinstance(run.get("app"), dict) and positive_id(run["app"].get("id")), "check app missing")
    return runs


class CiEvidenceError(RuntimeError):
    pass


def ci_require(condition: Any, reason: str) -> None:
    if not condition:
        raise CiEvidenceError(f"CI policy/evidence unknown: {reason}; merge blocked")


def positive_id(value: Any) -> bool:
    return type(value) is int and value > 0


def git_sha(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) is not None


async def ci_json(*args: str) -> Any:
    try:
        return json.loads(await run_gh(*args))
    except (RuntimeError, ValueError) as error:
        raise CiEvidenceError(f"CI evidence lookup failed: {error}; merge blocked") from error


async def ci_pages(endpoint: str, key: str | None = None, sha: str | None = None,
                   *, item_ids: bool = False) -> list[dict[str, Any]]:
    # gh follows every Link header; slurp preserves page boundaries for validation.
    pages = await ci_json("api", "--method", "GET", "--paginate", "--slurp",
                          f"repos/{{owner}}/{{repo}}/{endpoint}", "-f", "per_page=100")
    ci_require(isinstance(pages, list) and pages, "missing API pages")
    items: list[dict[str, Any]] = []
    total = None
    for index, page in enumerate(pages):
        if key is not None:
            ci_require(isinstance(page, dict), "invalid API page")
            count = page.get("total_count")
            ci_require(type(count) is int and count >= 0, "missing total_count")
            ci_require(total is None or total == count, "total_count changed during pagination")
            total = count
            if sha is not None:
                ci_require(page.get("sha") == sha, "status head mismatch")
            batch = page.get(key)
        else:
            batch = page
        ci_require(isinstance(batch, list) and len(batch) <= 100, "invalid API collection")
        ci_require(index == len(pages) - 1 or len(batch) == 100, "incomplete API page")
        ci_require(all(isinstance(item, dict) for item in batch), "invalid API item")
        items.extend(batch)
    ci_require(total is None or total == len(items), "incomplete API count")
    identities = [item.get("id") if key or item_ids else (item.get("ruleset_id"), item.get("type")) for item in items]
    if key or item_ids:
        ci_require(all(positive_id(identity) for identity in identities), "missing API item identity")
    else:
        ci_require(all(positive_id(identity[0]) and isinstance(identity[1], str) for identity in identities), "missing rule identity")
    ci_require(len(set(identities)) == len(identities), "duplicate API items/pages")
    return items


async def get_commit_statuses(sha: str) -> list[dict[str, Any]]:
    statuses = await ci_pages(f"commits/{sha}/status", "statuses", sha)
    for status in statuses:
        ci_require(isinstance(status.get("context"), str) and status["context"], "status context missing")
        ci_require(status.get("state") in {"pending", "success", "failure", "error"}, "unknown commit status")
    return statuses


async def get_check_suites(sha: str) -> list[dict[str, Any]]:
    suites = await ci_pages(f"commits/{sha}/check-suites", "check_suites")
    ci_require(all(suite.get("head_sha") == sha for suite in suites), "suite head mismatch")
    ci_require(all(suite.get("status") in {"queued", "in_progress", "completed", "waiting", "pending", "requested"} for suite in suites), "unknown suite status")
    ci_require(all(type(suite.get("latest_check_runs_count")) is int and suite["latest_check_runs_count"] >= 0
                   and isinstance(suite.get("app"), dict) and positive_id(suite["app"].get("id"))
                   and isinstance(suite["app"].get("slug"), str) and suite["app"]["slug"]
                   for suite in suites), "suite check count/app missing")
    return suites


# These rules do not require a CI result. GitHub still enforces their other gates.
NON_CI_RULES = {
    "creation", "update", "deletion", "non_fast_forward", "required_linear_history",
    "required_signatures", "pull_request", "commit_message_pattern",
    "commit_author_email_pattern", "committer_email_pattern", "branch_name_pattern",
    "tag_name_pattern", "file_path_restriction", "max_file_path_length",
    "file_extension_restriction", "max_file_size",
}


async def required_ci_checks(pr: PrInfo) -> list[tuple[str, int | None]]:
    ci_require(isinstance(pr.base_branch, str) and pr.base_branch, "PR base branch missing")
    ci_require(git_sha(pr.base_sha) and git_sha(pr.head_sha), "PR base/head SHA missing")
    # Ref.branchProtectionRule identifies the applicable classic rule. A successful
    # explicit null is absence; a REST 404 (which can hide permissions) is not.
    payload = await ci_json("api", "graphql", "-F", "owner={owner}", "-F", "name={repo}",
                            "-f", f"ref=refs/heads/{pr.base_branch}", "-f", "query=" + """
      query($owner: String!, $name: String!, $ref: String!) {
        repository(owner: $owner, name: $name) {
          ref(qualifiedName: $ref) {
            name target { oid }
            branchProtectionRule {
              requiresStatusChecks requiredStatusChecks { context app { databaseId } }
              requiresDeployments requiredDeploymentEnvironments
            }
          }
        }
      }
    """)
    ci_require(isinstance(payload, dict) and not payload.get("errors"), "GraphQL policy errors")
    ci_require(isinstance(payload.get("data"), dict), "GraphQL data missing")
    repository = payload["data"].get("repository")
    ci_require(isinstance(repository, dict) and isinstance(repository.get("ref"), dict), "base ref unavailable")
    ref = repository["ref"]
    ci_require(ref.get("name") == pr.base_branch and isinstance(ref.get("target"), dict) and ref["target"].get("oid") == pr.base_sha, "base changed during policy lookup")
    ci_require("branchProtectionRule" in ref, "classic protection missing")
    required: list[tuple[str, int | None]] = []
    classic = ref["branchProtectionRule"]
    if classic is not None:
        ci_require(isinstance(classic, dict) and type(classic.get("requiresStatusChecks")) is bool, "invalid classic protection")
        ci_require(classic.get("requiresDeployments") is False
                   and classic.get("requiredDeploymentEnvironments") == [],
                   "classic deployment requirements present or unknown")
        ci_require("requiredStatusChecks" in classic, "classic status requirements missing")
        checks = classic.get("requiredStatusChecks")
        if checks is None and classic["requiresStatusChecks"] is False:
            checks = []
        ci_require(isinstance(checks, list), "classic status requirements missing")
        ci_require(classic["requiresStatusChecks"] or not checks, "inconsistent classic protection")
        for check in checks:
            ci_require(isinstance(check, dict) and "app" in check, "classic check app missing")
            app = check["app"]
            ci_require(app is None or isinstance(app, dict) and positive_id(app.get("databaseId")), "invalid required app")
            required.append((check.get("context"), app["databaseId"] if app else None))
        ci_require(not classic["requiresStatusChecks"] or checks, "classic required checks unspecified")
    rules = await ci_pages(f"rules/branches/{quote(pr.base_branch, safe='')}")
    for rule in rules:
        kind = rule.get("type")
        if kind == "required_status_checks":
            parameters = rule.get("parameters")
            ci_require(isinstance(parameters, dict) and isinstance(parameters.get("required_status_checks"), list), "ruleset checks missing")
            for check in parameters["required_status_checks"]:
                ci_require(isinstance(check, dict), "invalid required check")
                app = check.get("integration_id")
                ci_require(app is None or positive_id(app), "invalid required integration")
                required.append((check.get("context"), app))
        else:
            ci_require(kind in NON_CI_RULES, f"unsupported rule {kind}")
    ci_require(all(isinstance(context, str) and context for context, _ in required), "required context missing")
    return required


async def has_workflow_files(sha: str) -> bool:
    tree = await ci_json("api", "--method", "GET", f"repos/{{owner}}/{{repo}}/git/trees/{sha}", "-f", "recursive=1")
    ci_require(isinstance(tree, dict) and tree.get("truncated") is False and isinstance(tree.get("tree"), list), "incomplete workflow tree")
    ci_require(git_sha(tree.get("sha")), "workflow tree identity missing")
    entries = tree["tree"]
    ci_require(all(isinstance(entry, dict) and isinstance(entry.get("path"), str) and entry["path"]
                   and entry.get("type") in {"tree", "blob", "commit"} and git_sha(entry.get("sha"))
                   for entry in entries), "invalid workflow tree entry")
    ci_require(len({entry["path"] for entry in entries}) == len(entries), "duplicate workflow tree entries")
    return any(re.fullmatch(r"\.github/workflows/[^/]+\.ya?ml", entry["path"]) for entry in entries)


async def attribute_status_apps(statuses: list[dict[str, Any]], required: list[tuple[str, int | None]], sha: str) -> None:
    # Commit statuses omit app.id. Resolve installation-token authors via the
    # documented <app-slug>[bot] account, verifying both bot and application IDs.
    contexts = {context for context, app in required if app is not None}
    if not any(status["context"] in contexts for status in statuses):
        return
    # The combined /status endpoint omits creator. /statuses includes the
    # author and returns history newest first; bind that history to this snapshot.
    history = await ci_pages(f"commits/{sha}/statuses", item_ids=True)
    latest: dict[str, dict[str, Any]] = {}
    for status in history:
        ci_require(isinstance(status.get("context"), str) and status["context"], "status context missing")
        ci_require(status.get("state") in {"pending", "success", "failure", "error"}, "unknown commit status")
        latest.setdefault(status["context"], status)
    identities: dict[str, tuple[int, int]] = {}
    for status in statuses:
        if status["context"] not in contexts:
            continue
        full_status = latest.get(status["context"])
        ci_require(full_status is not None and full_status["id"] == status["id"]
                   and full_status["state"] == status["state"], "required status history mismatch")
        creator = full_status.get("creator")
        ci_require(isinstance(creator, dict) and positive_id(creator.get("id"))
                   and isinstance(creator.get("login"), str) and creator.get("type") in {"Bot", "User"},
                   "required status creator unavailable")
        if creator["type"] != "Bot":
            continue
        login = creator["login"]
        ci_require(login.endswith("[bot]") and len(login) > 5, "required status app identity unknown")
        slug = login[:-5]
        if login not in identities:
            app = await ci_json("api", "--method", "GET", f"apps/{quote(slug, safe='')}")
            bot = await ci_json("api", "--method", "GET", f"users/{quote(login, safe='')}")
            ci_require(isinstance(app, dict) and app.get("slug") == slug and positive_id(app.get("id")), "status app lookup mismatch")
            ci_require(isinstance(bot, dict) and bot.get("login") == login and bot.get("type") == "Bot"
                       and positive_id(bot.get("id")), "status bot lookup mismatch")
            identities[login] = (bot["id"], app["id"])
        bot_id, app_id = identities[login]
        ci_require(creator["id"] == bot_id, "status creator identity mismatch")
        status["app"] = {"id": app_id}


async def failed_suite_replaced(suite: dict[str, Any], runs: list[dict[str, Any]],
                                suites: list[dict[str, Any]]) -> bool:
    # Preserve the existing latest-job (name/app) semantics for completed suites.
    # Never discard an entire app's older suites based on an unrelated green job.
    if not suite["latest_check_runs_count"] or suite.get("conclusion") not in {
        "failure", "timed_out", "cancelled", "action_required", "stale", "startup_failure",
    }:
        return False
    old_runs = await ci_pages(f"check-suites/{suite['id']}/check-runs", "check_runs")
    ci_require(len(old_runs) == suite["latest_check_runs_count"], "suite check count changed")
    for old in old_runs:
        ci_require(old.get("head_sha") == suite["head_sha"]
                   and (old.get("check_suite") or {}).get("id") == suite["id"]
                   and (old.get("app") or {}).get("id") == suite["app"]["id"]
                   and isinstance(old.get("name"), str) and old["name"], "suite check identity mismatch")
    current = dedupe_check_runs(runs)
    accepted_suites = {item["id"] for item in suites if item["status"] == "completed"
                       and item.get("conclusion") in {"success", "skipped", "neutral"}
                       and item["app"]["id"] == suite["app"]["id"]}
    for old in old_runs:
        replacements = [run for run in current if run["name"] == old["name"]
                        and run["app"]["id"] == suite["app"]["id"] and run["id"] > old["id"]
                        and (run.get("check_suite") or {}).get("id") in accepted_suites
                        and run["status"] == "completed" and run.get("conclusion") in {"success", "skipped", "neutral"}]
        if old.get("status") != "completed" or not replacements:
            return False
        old_time, new_time = check_timestamp(old), check_timestamp(replacements[0])
        if old_time is None or new_time is None or new_time <= old_time:
            return False
    return True


async def collect_ci_summary(pr: PrInfo) -> CheckSummary:
    required = await required_ci_checks(pr)
    runs = await get_check_runs(pr.head_sha)
    statuses = await get_commit_statuses(pr.head_sha)
    await attribute_status_apps(statuses, required, pr.head_sha)
    suites = await get_check_suites(pr.head_sha)
    # Keep status contexts separate from check names and bind required checks to
    # their app when specified. A same-named result from another app cannot pass.
    checks = runs + [dict(status, name=status["context"],
                         status="in_progress" if status["state"] == "pending" else "completed",
                         conclusion=status["state"], ci_source="status") for status in statuses]
    summary = summarize_checks(checks)
    missing = [context for context, app in required if not any(
        check["name"] == context and (app is None or (check.get("app") or {}).get("id") == app)
        for check in checks)]
    if missing:
        summary.pending = True
        summary.failures = [f"required check missing: {name}" for name in missing] + summary.failures
    for suite in suites:
        # GitHub auto-creates empty queued suites for installed check-writing
        # apps. They are no running job and must not hold green checks open.
        # Actions suites can represent an expected workflow awaiting its jobs.
        if (suite["status"] == "queued" and suite.get("conclusion") is None
                and suite["latest_check_runs_count"] == 0 and suite["app"]["slug"] != "github-actions"):
            continue
        if suite["status"] != "completed":
            summary.pending = True
            if suite["latest_check_runs_count"] == 0:
                summary.failures.append(f"CI expected: check suite {suite['id']} has no check runs")
        elif suite.get("conclusion") not in {"success", "skipped", "neutral"}:
            if await failed_suite_replaced(suite, runs, suites):
                continue
            summary.failed = True
            summary.failures.append(f"check suite {suite['id']}: {suite.get('conclusion') or 'missing conclusion'}")
    if checks or required:
        return summary
    if summary.failed:
        return summary
    reasons = []
    if suites:
        reasons.append("head check suites")
    if await ci_pages("actions/workflows", "workflows"):
        reasons.append("configured Actions workflows (including disabled)")
    for sha in dict.fromkeys([pr.base_sha, pr.head_sha]):
        if await has_workflow_files(sha):
            reasons.append(f"workflow files at {short_sha(sha)}")
    if await get_check_runs(pr.base_sha) or await get_commit_statuses(pr.base_sha) or await get_check_suites(pr.base_sha):
        reasons.append("CI signals at PR base")
    if reasons:
        summary.failures = ["CI expected: " + ", ".join(reasons)]
        return summary
    return CheckSummary(False, False, [], {}, no_ci=True)


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
    latest_by_name: dict[tuple, dict[str, Any]] = {}
    for check in check_runs:
        name = (check.get("name", "unknown"), check.get("ci_source", "check"), (check.get("app") or {}).get("id"))
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
    if summary.no_ci:
        return "GitHub CI not configured and not required; local Test (AI) evidence remains the gate."
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
    elif evidence.pr.state != "OPEN":
        failures.append("GitHub PR is not open.")
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
    if current_issue_identifier() is None:
        raise LabelRefreshError("Missing issue identity for the App label gate.")
    if bound_request is not None:
        result = bound_request("labels")
        if result.get("ok") is True and isinstance(result.get("labels"), list):
            return result["labels"]
        raise LabelRefreshError("Bound live label lookup failed.")
    raise AppLabelLookupRequired("Live labels must be read through the bound Linear tool.")


def current_issue_identifier() -> str | None:
    issue_identifier = os.environ.get(ISSUE_IDENTIFIER_ENV)
    if issue_identifier is None or not issue_identifier.strip():
        return None
    return issue_identifier


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
    latest_ack: datetime | None = None,
) -> list[dict[str, Any]]:
    candidates = dedupe_reviews(reviews)
    for decisive in latest_decisive_reviews(reviews):
        if review_state(decisive) == "CHANGES_REQUESTED" and decisive not in candidates:
            candidates.append(decisive)
    return [
        review
        for review in candidates
        if is_blocking_review(review, review_requested_at)
        and not (
            review_state(review) == "COMMENTED"
            and latest_ack is not None
            and review_timestamp(review) is not None
            and review_timestamp(review) <= latest_ack
        )
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
    blocking_reviews = filter_blocking_reviews(reviews, review_request_at, latest_codex_issue_reply_time(issue_comments))
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
        try:
            await asyncio.wait_for(checks_done.wait(), timeout=POLL_SECONDS)
        except asyncio.TimeoutError:
            pass


async def wait_for_checks(pr: PrInfo, checks_done: asyncio.Event) -> None:
    print("Checking GitHub CI requirements and results...", flush=True)
    missing_seconds = 0
    while True:
        try:
            summary = await collect_ci_summary(pr)
        except CiEvidenceError as error:
            print(str(error), flush=True)
            raise SystemExit(3) from error
        if summary.failed:
            print("Checks failed:")
            for failure in summary.failures:
                print(f"- {failure}")
            raise SystemExit(3)
        if not summary.pending:
            print(check_summary_message(summary))
            checks_done.set()
            return
        if summary.failures:
            missing_seconds += POLL_SECONDS
            print("; ".join(summary.failures), flush=True)
            if missing_seconds >= CHECKS_APPEAR_TIMEOUT_SECONDS:
                print("Expected GitHub CI checks still missing after 120s; merge blocked.")
                raise SystemExit(3)
        else:
            missing_seconds = 0
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
    checks_task = asyncio.create_task(wait_for_checks(pr, checks_done))

    async def head_monitor() -> None:
        while True:
            current = await get_pr_info(branch)
            if is_merge_conflicting(current):
                print(
                    "PR has merge conflicts. Resolve/rebase against main and push "
                    "before running land_watch again.",
                )
                raise SystemExit(5)
            if (current.head_sha, current.base_branch, current.base_sha, current.state) != (head_sha, pr.base_branch, pr.base_sha, "OPEN"):
                print("PR head/base/state updated; repeat the land checks")
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


def request_bound_checkpoint(operation: str) -> dict:
    print(BOUND_REQUEST + json.dumps({"operation": operation}), flush=True)
    line = sys.stdin.readline()
    if not line:
        raise RuntimeError("Bound runtime disconnected before merge.")
    result = json.loads(line)
    if not isinstance(result, dict):
        raise RuntimeError("Invalid bound checkpoint response.")
    return result


async def merge_bound(expected_head: str, title: str) -> None:
    """The trusted runtime owns the pipe; no credential or approval token is passed to the shell."""
    global bound_request
    bound_request = request_bound_checkpoint
    await watch_pr()
    evidence = await require_merge_preflight()
    current = evidence.pr
    if evidence.branch != f"symphony/{current_issue_identifier()}":
        raise RuntimeError("Branch does not belong to the bound issue.")
    if current.head_sha != expected_head or await run_git("status", "--porcelain"):
        raise RuntimeError("Merge head changed or workspace is dirty.")
    labels = await current_issue_labels()
    issue_comments, review_comments, reviews, review_request_at = await fetch_review_context(current.number)
    raise_on_human_feedback(issue_comments, review_comments, reviews, review_request_at)
    raise_on_missing_manual_review_approval(labels, current, reviews)
    # Do not reuse the watch decision after labels/reviews or across attempts.
    summary = await collect_ci_summary(current)
    if summary.failed or summary.pending:
        raise CiEvidenceError("GitHub CI changed or remains incomplete; repeat the bound merge.")
    fresh = await require_merge_preflight()
    if (fresh.branch != evidence.branch or fresh.pr != current
            or current.mergeable != "MERGEABLE" or current.merge_state not in {"CLEAN", "HAS_HOOKS"}
            or await run_git("status", "--porcelain")):
        raise RuntimeError("PR/base/head/mergeability changed or workspace is dirty; repeat the bound merge.")
    remote = (await run_git("ls-remote", "--exit-code", "--heads", "origin", evidence.branch)).split()
    if remote != [expected_head, f"refs/heads/{evidence.branch}"]:
        raise RuntimeError("Remote branch head does not match the tested merge head.")
    print(check_summary_message(summary), flush=True)
    # The final fresh Linear scan executes in the bound parent, after GitHub
    # gates. This remaining API/action interval cannot be made atomic.
    checkpoint = bound_request("merge")
    if checkpoint.get("ok") is not True:
        raise SystemExit(COMMENT_CHECKPOINT_EXIT)
    if checkpoint.get("labels") != labels:
        raise RuntimeError("Linear labels changed during merge checks; repeat the bound merge.")
    await run_gh("pr", "merge", str(current.number), "--merge", "--match-head-commit", expected_head, "--subject", title)
    result = json.loads(await run_gh("pr", "view", str(current.number), "--json", "state,mergeCommit,url"))
    if result.get("state") != "MERGED" or not (result.get("mergeCommit") or {}).get("oid"):
        raise RuntimeError("Merge result is not confirmed.")
    print("SYMPHONY_MERGE_RESULT " + json.dumps(result), flush=True)


if __name__ == "__main__":
    try:
        if len(sys.argv) == 4 and sys.argv[1] == "--bound-merge":
            asyncio.run(merge_bound(sys.argv[2], sys.argv[3]))
        else:
            asyncio.run(watch_pr())
    except SystemExit as exc:
        raise SystemExit(exc.code) from None
