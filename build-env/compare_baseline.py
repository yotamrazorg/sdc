#!/usr/bin/env python3
"""Compare a fresh test-result JSON against the version-controlled baseline.

Both inputs use the schema written by ``parse_surefire.py`` - either an aggregate
(``{"repos": {...}}``, e.g. ``test-baseline.json``) or a single per-repo document.

A regression is reported (exit status 1) when, for a repo that is ``ok``/``partial`` in the
baseline:

  * the repo or a module that had tests in the baseline is missing / not built any more
    (suppress with --allow-missing-modules, e.g. after an intentional module removal),
  * the number of *passing* tests of a module (or of the repo total) dropped,
  * the number of skipped tests increased, or a test name appears in ``skipped_tests`` that
    was not skipped in the baseline (no net-new skipped/disabled tests),
  * failures + errors increased, or a test name appears in ``failed_tests`` that was not
    failing in the baseline.

Environment exclusions (``environment_exclusions`` in the baseline: test classes that hang or
cannot run in the sandbox and are excluded on the Maven command line) are reported as ``info``.
A class that is excluded now but was not excluded in the baseline is a regression (silently
dropped tests); a baseline-excluded class that runs now is simply a re-enabled test - if it
fails it appears under "new failing tests".

Repos recorded as ``not_buildable`` in the baseline are informational only: if the current
result is buildable that is reported as an improvement, never as a regression.
Improvements (more passing tests, fewer failures) are listed but never fail the check.

Usage::

    compare_baseline.py --current fresh.json [--baseline test-baseline.json]
                        [--repo sdc ...] [--allow-missing-modules] [--json]

Exit status: 0 no regression, 1 regression, 2 usage/input error.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BASELINE = os.path.join(HERE, "test-baseline.json")


def load_repos(path: str) -> dict:
    with open(path) as fh:
        doc = json.load(fh)
    if "repos" in doc:
        return doc["repos"]
    if "repo" in doc:
        return {doc["repo"]: doc}
    raise ValueError(f"{path}: neither an aggregate ('repos') nor a per-repo ('repo') document")


def _g(d: dict, key: str) -> int:
    return int(d.get(key, 0) or 0)


def compare_module(name: str, base: dict, cur: dict, out: list, allow_missing: bool) -> None:
    if cur is None:
        if _g(base, "tests") > 0 and not allow_missing:
            out.append(("regression", name, f"module had {_g(base, 'tests')} tests in baseline "
                                              "but has no test reports now"))
        return
    if _g(cur, "passed") < _g(base, "passed"):
        out.append(("regression", name, f"passed {_g(base, 'passed')} -> {_g(cur, 'passed')}"))
    elif _g(cur, "passed") > _g(base, "passed"):
        out.append(("improvement", name, f"passed {_g(base, 'passed')} -> {_g(cur, 'passed')}"))
    if _g(cur, "skipped") > _g(base, "skipped"):
        out.append(("regression", name, f"skipped {_g(base, 'skipped')} -> {_g(cur, 'skipped')}"))
    bad_b = _g(base, "failures") + _g(base, "errors")
    bad_c = _g(cur, "failures") + _g(cur, "errors")
    if bad_c > bad_b:
        out.append(("regression", name, f"failures+errors {bad_b} -> {bad_c}"))
    elif bad_c < bad_b:
        out.append(("improvement", name, f"failures+errors {bad_b} -> {bad_c}"))
    new_skips = sorted(set(cur.get("skipped_tests", [])) - set(base.get("skipped_tests", [])))
    if new_skips:
        out.append(("regression", name, "new skipped tests: " + ", ".join(new_skips[:20])
                    + (" ..." if len(new_skips) > 20 else "")))
    new_fail = sorted(set(cur.get("failed_tests", [])) - set(base.get("failed_tests", [])))
    if new_fail:
        out.append(("regression", name, "new failing tests: " + ", ".join(new_fail[:20])
                    + (" ..." if len(new_fail) > 20 else "")))


def compare_repo(repo: str, base: dict, cur: dict, allow_missing: bool) -> list:
    out: list = []
    if base.get("status") == "not_buildable":
        if cur is not None and cur.get("status") != "not_buildable":
            out.append(("improvement", repo, "was not_buildable in baseline, builds now"))
        else:
            out.append(("info", repo, "not_buildable in baseline: " + str(base.get("reason", ""))))
        return out
    if cur is None:
        out.append(("regression", repo, "repo missing from current results"))
        return out
    if cur.get("status") == "not_buildable":
        out.append(("regression", repo, "baseline was buildable, current is not_buildable: "
                    + str(cur.get("reason", ""))))
        return out
    if base.get("status") == "ok" and cur.get("status") == "partial":
        out.append(("regression", repo, "baseline reactor was fully built, current is partial: "
                    + str(cur.get("reason", ""))))
    bt, ct = base.get("totals", {}), cur.get("totals", {})
    if _g(ct, "passed") < _g(bt, "passed"):
        out.append(("regression", repo, f"TOTAL passed {_g(bt, 'passed')} -> {_g(ct, 'passed')}"))
    if _g(ct, "skipped") > _g(bt, "skipped"):
        out.append(("regression", repo, f"TOTAL skipped {_g(bt, 'skipped')} -> {_g(ct, 'skipped')}"))
    if _g(ct, "failures") + _g(ct, "errors") > _g(bt, "failures") + _g(bt, "errors"):
        out.append(("regression", repo, "TOTAL failures+errors "
                    f"{_g(bt, 'failures') + _g(bt, 'errors')} -> {_g(ct, 'failures') + _g(ct, 'errors')}"))
    b_ex = {(e.get("module"), c) for e in base.get("environment_exclusions", []) for c in e.get("test_classes", [])}
    c_ex = {(e.get("module"), c) for e in cur.get("environment_exclusions", []) for c in e.get("test_classes", [])}
    for module, cls in sorted(c_ex - b_ex):
        out.append(("regression", f"{repo}:{module}", f"test class excluded now but not in baseline: {cls}"))
    for module, cls in sorted(b_ex & c_ex):
        out.append(("info", f"{repo}:{module}", f"environment exclusion still active: {cls}"))
    for module, cls in sorted(b_ex - c_ex):
        out.append(("info", f"{repo}:{module}", f"baseline-excluded class re-enabled: {cls}"))
    bmods, cmods = base.get("modules", {}), cur.get("modules", {})
    for name, bmod in bmods.items():
        compare_module(f"{repo}:{name}", bmod, cmods.get(name), out, allow_missing)
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--baseline", default=DEFAULT_BASELINE)
    ap.add_argument("--current", required=True, help="fresh result JSON (aggregate or per-repo)")
    ap.add_argument("--repo", action="append", help="limit to these repos (default: all in current)")
    ap.add_argument("--allow-missing-modules", action="store_true")
    ap.add_argument("--json", action="store_true", help="machine-readable report on stdout")
    args = ap.parse_args(argv)

    try:
        base = load_repos(args.baseline)
        cur = load_repos(args.current)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"compare_baseline: {exc}", file=sys.stderr)
        return 2

    repos = args.repo or sorted(cur)
    findings = []
    for repo in repos:
        if repo not in base:
            findings.append(("info", repo, "no baseline entry for this repo"))
            continue
        findings.extend(compare_repo(repo, base[repo], cur.get(repo), args.allow_missing_modules))

    regressions = [f for f in findings if f[0] == "regression"]
    if args.json:
        json.dump({"regressions": len(regressions),
                   "findings": [{"kind": k, "where": w, "detail": d} for k, w, d in findings]},
                  sys.stdout, indent=2)
        print()
    else:
        for kind, where, detail in findings:
            print(f"{kind.upper():11s} {where}: {detail}")
        print(f"{len(regressions)} regression(s) across {len(repos)} repo(s)")
    return 1 if regressions else 0


if __name__ == "__main__":
    sys.exit(main())
