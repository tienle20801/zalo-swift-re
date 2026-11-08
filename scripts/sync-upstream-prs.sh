#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

UPSTREAM_URL="https://github.com/qnguyen3/zalo-swift-re.git"
PR_REFSPEC="+refs/pull/*/head:refs/remotes/upstream/pr/*"

if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream "$UPSTREAM_URL"
fi

if ! git config --get-all remote.upstream.fetch | grep -Fq "$PR_REFSPEC"; then
    git config --add remote.upstream.fetch "$PR_REFSPEC"
fi

echo "=== [1/2] Fetching upstream branches & Pull Requests ==="
git fetch upstream --prune

echo ""
echo "=== [2/2] Open Pull Requests on qnguyen3/zalo-swift-re ==="
curl -s -H "User-Agent: sync-upstream-prs" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/qnguyen3/zalo-swift-re/pulls?state=open&per_page=20" | python3 -c '
import sys, json, subprocess

try:
    prs = json.load(sys.stdin)
except Exception as e:
    print("Failed to parse GitHub API response:", e)
    sys.exit(0)

if not isinstance(prs, list) or not prs:
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
    try:
        stat = subprocess.check_output(
            ["git", "--no-pager", "diff", "--shortstat", f"upstream/main...{ref}"],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
        if stat:
            print(f"  Diff vs upstream/main: {stat}")
    except Exception:
        pass
'
