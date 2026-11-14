#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

UPSTREAM_URL="https://github.com/qnguyen3/zalo-swift-re.git"
PR_REFSPEC="+refs/pull/*/head:refs/remotes/upstream/pr/*"
NO_FETCH=0

for arg in "$@"; do
    case "$arg" in
        --no-fetch) NO_FETCH=1 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--no-fetch]"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream "$UPSTREAM_URL"
fi

if ! git config --get-all remote.upstream.fetch | grep -Fq "$PR_REFSPEC"; then
    git config --add remote.upstream.fetch "$PR_REFSPEC"
fi

echo "=== [1/3] Fetching upstream branches & Pull Requests ==="
if [[ "$NO_FETCH" -eq 1 ]]; then
    echo "Skipped fetch (--no-fetch)."
else
    git fetch upstream --prune
fi

API_JSON=""
if [[ "$NO_FETCH" -eq 0 ]]; then
    API_JSON="$(curl -fsSL -H "User-Agent: sync-upstream-prs" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/qnguyen3/zalo-swift-re/pulls?state=open&per_page=30" 2>/dev/null || true)"
fi

SYNC_NO_FETCH="$NO_FETCH" SYNC_API_JSON="$API_JSON" python3 - <<'PY'
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path


def run_git(*args: str) -> str:
    return subprocess.check_output(
        ["git", "--no-pager", *args],
        stderr=subprocess.DEVNULL,
        text=True,
    )


def ref_exists(ref: str) -> bool:
    proc = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", ref],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return proc.returncode == 0


def normalize_subject(subject: str) -> str:
    return " ".join(subject.strip().lower().split())


def load_target_index(target: str) -> tuple[dict[str, str], list[tuple[str, str]]]:
    raw = run_git("log", target, "--format=%H%x1f%s%x1f%b%x1e")
    subjects: dict[str, str] = {}
    commit_texts: list[tuple[str, str]] = []
    for record in raw.split("\x1e"):
        record = record.strip()
        if not record:
            continue
        parts = record.split("\x1f", 2)
        if len(parts) < 2:
            continue
        full_sha = parts[0].strip()
        short_sha = full_sha[:7]
        subject = parts[1].strip()
        body = parts[2].strip() if len(parts) > 2 else ""
        norm = normalize_subject(subject)
        if norm and norm not in subjects:
            subjects[norm] = short_sha
        commit_texts.append((short_sha, f"{subject}\n{body}".strip()))
    return subjects, commit_texts


def load_memory_text() -> str:
    mem_path = Path(".agy/memory/resolved_bugs.md")
    if mem_path.is_file():
        return mem_path.read_text(encoding="utf-8", errors="replace")
    return ""


def find_sha_in_commits(sha7: str, commit_texts: list[tuple[str, str]]) -> str | None:
    pattern = re.compile(rf"\b{re.escape(sha7)}\b")
    for local_sha, text in commit_texts:
        if pattern.search(text):
            return local_sha
    return None


def find_pr_refs_in_commits(pr_num: int | str, commit_texts: list[tuple[str, str]]) -> list[str]:
    pattern = re.compile(rf"(?:\bPR\s*#|\bpr/){re.escape(str(pr_num))}\b")
    return [local_sha for local_sha, text in commit_texts if pattern.search(text)]


def parse_cherry(args: list[str]) -> list[tuple[str, str, str]]:
    try:
        out = run_git("cherry", "-v", *args)
    except subprocess.CalledProcessError:
        return []
    commits: list[tuple[str, str, str]] = []
    for line in out.splitlines():
        if len(line) < 3 or line[0] not in ("+", "-") or line[1] != " ":
            continue
        rest = line[2:].split(" ", 1)
        if len(rest) == 2:
            commits.append((line[0], rest[0], rest[1]))
    return commits


def classify_commit(
    sign: str,
    sha: str,
    subject: str,
    subjects: dict[str, str],
    commit_texts: list[tuple[str, str]],
    memory_text: str,
    *,
    allow_pr_ref: bool = False,
) -> tuple[str, str]:
    if sign == "-":
        return "matched", "patch-id"

    norm = normalize_subject(subject)
    if norm in subjects:
        return "matched", f"subject->{subjects[norm]}"

    sha7 = sha[:7]
    ref_sha = find_sha_in_commits(sha7, commit_texts)
    if ref_sha:
        return "matched", f"ref->{ref_sha}"

    if allow_pr_ref:
        pr_match = re.search(r"\(#(\d+)\)\s*$", subject)
        pr_num = pr_match.group(1) if pr_match else None
        if not pr_num:
            try:
                merge_subj = run_git(
                    "log", "--ancestry-path", "--merges", "--reverse", "-n", "1",
                    f"{sha}..upstream/main", "--format=%s"
                ).strip()
                m_merge = re.search(r"Merge pull request #(\d+)\b", merge_subj)
                if m_merge:
                    pr_num = m_merge.group(1)
            except subprocess.CalledProcessError:
                pass
        if pr_num:
            pr_hits = find_pr_refs_in_commits(pr_num, commit_texts)
            if pr_hits:
                return "matched", f"PR#{pr_num}->{pr_hits[0]}"

    if memory_text and re.search(rf"\b{re.escape(sha7)}\b", memory_text):
        return "noted", "memory"

    return "unmatched", "NEW"


def fallback_local_prs() -> list[dict]:
    out = run_git("for-each-ref", "--format=%(refname:short)%09%(objectname:short)%09%(committerdate:iso8601)%09%(subject)", "refs/remotes/upstream/pr/")
    items: list[tuple[int, dict]] = []
    for line in out.splitlines():
        parts = line.split("\t", 3)
        if len(parts) < 4:
            continue
        ref, sha, date, subj = parts
        m = re.search(r"/pr/(\d+)$", ref)
        if not m:
            continue
        num = int(m.group(1))
        items.append((
            num,
            {
                "number": num,
                "title": subj,
                "user": {"login": "local-ref"},
                "updated_at": date,
                "head": {"sha": sha},
                "html_url": f"https://github.com/qnguyen3/zalo-swift-re/pull/{num}",
            },
        ))
    items.sort(key=lambda pair: pair[0], reverse=True)
    return [item for _, item in items]


target = "main" if ref_exists("main") else "HEAD"
subjects, commit_texts = load_target_index(target)
memory_text = load_memory_text()

print("")
print(f"=== [2/3] Checking upstream/main vs local {target} ===")
if ref_exists("upstream/main"):
    um_commits = parse_cherry([target, "upstream/main"])
    if not um_commits:
        print(f"upstream/main is fully in {target} ancestry (0 commits ahead).")
    else:
        um_counts: Counter[str] = Counter()
        um_unmatched: list[tuple[str, str]] = []
        for sign, sha, subj in um_commits:
            status, reason = classify_commit(
                sign, sha, subj, subjects, commit_texts, memory_text, allow_pr_ref=True
            )
            if status == "matched":
                um_counts[reason.split("->", 1)[0]] += 1
            elif status == "noted":
                um_counts["memory"] += 1
            else:
                um_unmatched.append((sha[:7], subj))
        matched_n = len(um_commits) - len(um_unmatched)
        detail = ", ".join(f"{k}:{v}" for k, v in um_counts.items()) or "none"
        print(f"upstream/main vs {target}: {matched_n}/{len(um_commits)} commits integrated/referenced ({detail}), {len(um_unmatched)} unmatched")
        for sha7, subj in um_unmatched[:10]:
            print(f"  - [NEW] {sha7} {subj}")
        if len(um_unmatched) > 10:
            print(f"  ... (+{len(um_unmatched) - 10} more)")
else:
    print("upstream/main ref not found.")

print("")
print("=== [3/3] Open Pull Requests on qnguyen3/zalo-swift-re ===")

raw_api = os.environ.get("SYNC_API_JSON", "").strip()
no_fetch = os.environ.get("SYNC_NO_FETCH") == "1"
prs = None
if no_fetch:
    print("Offline mode (--no-fetch): showing local refs/remotes/upstream/pr/* (includes closed/merged PRs).")
elif raw_api:
    try:
        parsed = json.loads(raw_api)
        if isinstance(parsed, list):
            prs = parsed
        else:
            msg = parsed.get("message", "unexpected response") if isinstance(parsed, dict) else "unexpected response"
            print(f"GitHub API unavailable ({msg}); falling back to local refs/remotes/upstream/pr/*.")
    except Exception as exc:
        print(f"Failed to parse GitHub API response ({exc}); falling back to local refs/remotes/upstream/pr/*.")
else:
    print("GitHub API returned empty response; falling back to local refs/remotes/upstream/pr/*.")

if prs is None:
    prs = fallback_local_prs()

if not prs:
    print("No open pull requests found.")
    sys.exit(0)

for pr in prs:
    num = pr.get("number")
    title = pr.get("title", "")
    user = pr.get("user", {}).get("login", "")
    updated = pr.get("updated_at", "")
    sha = pr.get("head", {}).get("sha", "")[:7]
    ref = f"upstream/pr/{num}"
    url = pr.get("html_url", "")

    print(f"• PR #{num} [{sha}] by @{user} (updated {updated}): {title}")
    print(f"  Local ref: {ref} | URL: {url}")

    if not ref_exists(ref):
        print(f"  Status vs {target}: local ref {ref} not fetched.")
        continue

    try:
        stat = run_git("diff", "--shortstat", f"upstream/main...{ref}").strip()
        if stat:
            print(f"  Diff vs upstream/main: {stat}")
    except subprocess.CalledProcessError:
        pass

    pr_commits = parse_cherry([target, ref, "upstream/main"])
    if not pr_commits:
        print(f"  Status vs {target}: 0 commits ahead of upstream/main.")
        continue

    matched_reasons: Counter[str] = Counter()
    noted_commits: list[tuple[str, str]] = []
    unmatched_commits: list[tuple[str, str]] = []

    for sign, csha, csubj in pr_commits:
        status, reason = classify_commit(
            sign, csha, csubj, subjects, commit_texts, memory_text, allow_pr_ref=False
        )
        if status == "matched":
            matched_reasons[reason.split("->", 1)[0]] += 1
        elif status == "noted":
            noted_commits.append((csha[:7], csubj))
        else:
            unmatched_commits.append((csha[:7], csubj))

    matched_n = sum(matched_reasons.values())
    total_n = len(pr_commits)
    reason_str = ", ".join(f"{k}:{v}" for k, v in matched_reasons.items())
    parts = [f"{matched_n}/{total_n} matched" + (f" ({reason_str})" if reason_str else "")]
    if noted_commits:
        parts.append(f"{len(noted_commits)} noted in memory")
    parts.append(f"{len(unmatched_commits)} unmatched")
    print(f"  Status vs {target}: {', '.join(parts)}")

    pr_refs = find_pr_refs_in_commits(num, commit_texts)
    in_mem_pr = bool(memory_text and re.search(rf"\bPR\s*#{re.escape(str(num))}\b", memory_text))
    if unmatched_commits and (pr_refs or in_mem_pr):
        note_bits = []
        if pr_refs:
            note_bits.append(f"commits {', '.join(pr_refs[:4])}")
        if in_mem_pr:
            note_bits.append(".agy/memory/resolved_bugs.md")
        print(f"  Note: PR #{num} already referenced in {' & '.join(note_bits)} (selective/squashed integration).")

    for csha7, csubj in unmatched_commits[:15]:
        print(f"    - [NEW] {csha7} {csubj}")
    if len(unmatched_commits) > 15:
        print(f"    ... (+{len(unmatched_commits) - 15} more)")
PY
