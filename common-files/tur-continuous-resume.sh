#!/bin/bash
# tur-continuous-resume.sh -- pick the restore point for the continuous
# electron build so a new commit can pick up where an old one left off.
#
# The aarch64 build runs in ~200-minute slices. Each finished slice is
# snapshotted into two GitHub Actions artifacts, namespaced by arch + commit:
#   build-deps-<arch>-<sha>      /data + /home/builder/.termux-build tarball
#   build-status-<arch>-<sha>    build/ snapshot + .txt lists + debs/output
#
# prepare() starts a fresh lineage by default, so a fix commit used to pay the
# full ~19 h again even though older artifacts may be much deeper. This script
# finds the newest commit that has BOTH artifacts (a coherent pair): resuming
# from it continues the build with build-package.sh -c instead of restarting.
#
# Only the electron-44 continuous build produces these artifacts in this repo,
# so a found pair is always the electron-44 lineage.
#
# Usage (run in the merged repo, with GITHUB_REPOSITORY set):
#   common-files/tur-continuous-resume.sh select <arch>
#
# Prints nothing (exit 0) when no resumable pair exists, otherwise:
#   resume_sha=<40-hex sha>
#   resume_time=<ISO-8601 created_at of the newest artifact in the pair>
set -euo pipefail

cmd="${1:-}"
arch="${2:-}"
repo="${GITHUB_REPOSITORY:-}"

if [ "$cmd" != "select" ] || [ -z "$arch" ] || [ -z "$repo" ]; then
	echo "usage: tur-continuous-resume.sh select <arch> (GITHUB_REPOSITORY required)" >&2
	exit 2
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Collect every continuous-build artifact for this arch. per_page=100 covers
# dozens of rounds; the newest pair (what we want) is always on this page.
gh api "/repos/${repo}/actions/artifacts?per_page=100" \
	--jq '.artifacts[] | select(.name | test("^build-(deps|status)-'"${arch}"'-[0-9a-f]{40}$")) | [.name, .created_at] | @tsv' \
	>"$tmp"

awk -F '\t' -v arch="$arch" '
	{
		name = $1; created = $2
		if (name ~ "^build-deps-" arch "-[0-9a-f]{40}$") {
			sha = name; sub("^build-deps-" arch "-", "", sha)
			if (!(sha in dep) || created > dep[sha]) dep[sha] = created
		} else if (name ~ "^build-status-" arch "-[0-9a-f]{40}$") {
			sha = name; sub("^build-status-" arch "-", "", sha)
			if (!(sha in st) || created > st[sha]) st[sha] = created
		}
	}
	END {
		best = ""; best_time = ""
		for (sha in dep) {
			if (!(sha in st)) continue
			t = (dep[sha] > st[sha] ? dep[sha] : st[sha])
			if (best_time == "" || t > best_time) { best = sha; best_time = t }
		}
		if (best != "") {
			print "resume_sha=" best
			print "resume_time=" best_time
		}
	}
' "$tmp"
