#!/usr/bin/env python3
"""Reject builder patches whose hunks GNU patch would silently mangle.

GNU patch (2.7.x/2.8) reads a hunk body until BOTH line counts declared in
the "@@ -o,n +m,k @@" header are satisfied and then silently discards the
remaining body lines.  If those discarded lines carry '+'/'-' changes the
patch loses them while still exiting 0, and a hunk whose header disagrees
with its body also desyncs the parser so that the *following* hunks are
dropped with no diagnostic.  That is exactly how the electron-44 dav1d
config patch shipped a config.h with HAVE_SVE2 still enabled and then
failed three hours into the chromium build (see the r25/r26 patch series).

This scans one sed-expanded patch file and reports:

  * a hunk whose body is exhausted before its declared counts are met
    (GNU patch drops the whole hunk), and
  * a hunk whose discarded tail contains '+'/'-' content lines
    (GNU patch drops those lines).

Exit status 0 when the patch is safe, 1 otherwise.
"""
import re
import sys

HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
SECTION_END_RE = re.compile(r"^(?:diff |index |@@ |--- [ab]/|\+\+\+ [ab]/)")


def check(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()

    problems = []
    cur = None
    file_name = "?"

    def finish():
        nonlocal cur
        if cur is None:
            return
        old_need, new_need = cur["old"], cur["new"]
        old = new = 0
        met = False
        dropped = []
        for ln in cur["body"]:
            if ln.startswith("\\"):
                continue  # "\ No newline at end of file"
            if not met:
                if ln.startswith("-"):
                    old += 1
                elif ln.startswith("+"):
                    new += 1
                else:
                    old += 1
                    new += 1
                if old >= old_need and new >= new_need:
                    met = True
            else:
                dropped.append(ln)
        if not met:
            problems.append(
                "%s: hunk at line %d: header declares -%d,%d +%d,%d but the "
                "body only reaches %d old / %d new lines; GNU patch would "
                "drop this hunk silently"
                % (file_name, cur["hdr_line"], old_need, old_need,
                   new_need, new_need, old, new))
        else:
            lost = [ln for ln in dropped
                    if ln.startswith("+") or ln.startswith("-")]
            if lost:
                problems.append(
                    "%s: hunk at line %d: %d body line(s) after the declared "
                    "-%d,%d +%d,%d would be dropped, e.g. %s"
                    % (file_name, cur["hdr_line"], len(lost),
                       old_need, old_need, new_need, new_need,
                       ", ".join(repr(x) for x in lost[:3])))
        cur = None

    for i, ln in enumerate(lines, 1):
        if ln.startswith("--- "):
            file_name = ln[4:].split("\t", 1)[0].strip()
        m = HUNK_RE.match(ln)
        if m:
            finish()
            cur = {
                "hdr_line": i,
                "old": int(m.group(2)) if m.group(2) else 1,
                "new": int(m.group(4)) if m.group(4) else 1,
                "body": [],
            }
            continue
        if cur is not None:
            if SECTION_END_RE.match(ln):
                finish()
            else:
                cur["body"].append(ln)
    finish()

    if problems:
        sys.stderr.write("\n".join(problems) + "\n")
        return 1
    return 0


if __name__ == "__main__":
    rc = 0
    for arg in sys.argv[1:]:
        rc |= check(arg)
    sys.exit(1 if rc else 0)
