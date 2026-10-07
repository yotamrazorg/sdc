#!/usr/bin/env python3
"""Turn Maven surefire/failsafe XML reports into a machine-readable test baseline.

Sub-commands
------------
repo     Walk one repository checkout, parse every ``target/surefire-reports/TEST-*.xml``
         (and ``target/failsafe-reports/TEST-*.xml``) and write a per-repo JSON document.
         For repos that could not be built use ``--not-buildable --reason ...``.
merge    Combine several per-repo JSON documents into one aggregate (the version-controlled
         ``test-baseline.json``).

The output is deliberately free of timestamps, absolute paths and durations so that two runs
over the same tree produce byte-identical files.

Schema (``schema_version`` 1) of a per-repo document::

    {
      "repo": "sdc",
      "status": "ok" | "partial" | "not_buildable",
      "reason": "...",                       # only when not ok
      "jdk": {"version": "17.0.20.1", "select": "17"},
      "maven": "3.9.11",
      "commands": ["mvn ..."],
      "build_exit_codes": [0, 0],
      "totals": {"modules_with_tests": 12, "tests": 10, "passed": 7, "failures": 1,
                 "errors": 1, "skipped": 1},
      "modules": {
        "<module path relative to the repo root>": {
          "tests": .., "passed": .., "failures": .., "errors": .., "skipped": ..,
          "suites": <number of report files>,
          "failed_tests":  ["pkg.Class#method", ...],   # failures + errors
          "skipped_tests": ["pkg.Class#method", ...]
        }
      },
      "reactor": {"failed_modules": [...], "skipped_modules": [...], "success_modules": N},
      "prior_attempts": [ {"jdk": {...}, "status": "not_buildable", "reason": "..."} ],  # optional
      "environment_exclusions": [                    # only when the repo has some
        {"module": "catalog-dao", "test_classes": ["pkg.Class", ...],
         "category": "hangs_in_sandbox", "reason": "...", ...}
      ],
      "notes": [...]
    }

``environment_exclusions`` comes from ``baseline-exclusions.json``: test classes that were
*not executed* (excluded on the Maven command line, never by editing a pom) because they hang
or cannot run in the sandbox. They are NOT part of the module counts; modules they belong to
additionally carry ``environment_excluded_classes``. Later milestones that replace the
offending dependency (e.g. cassandra-unit -> Testcontainers) re-enable the classes and compare
against these entries explicitly.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

SCHEMA_VERSION = 1
REPORT_DIRS = ("surefire-reports", "failsafe-reports")
COUNT_KEYS = ("tests", "passed", "failures", "errors", "skipped")

# "[INFO] some-module ........ SUCCESS [  1.2 s]"  (also FAILURE / SKIPPED)
REACTOR_RE = re.compile(r"^\[(?:INFO|ERROR|WARNING)\]\s+(.+?)\s+\.{2,}\s+(SUCCESS|FAILURE|SKIPPED)\b")
MISSING_ARTIFACT_RE = re.compile(
    r"(Could not (?:find|resolve) artifact [^\s]+|Non-resolvable parent POM[^\n]*|"
    r"The following artifacts could not be resolved: [^\n]*|"
    r"Failed to read artifact descriptor for [^\s]+|"
    r"Could not transfer artifact [^\s]+|"
    r"Plugin [^\s]+ or one of its dependencies could not be resolved[^\n]*)"
)


def _empty_counts() -> dict:
    return {"tests": 0, "passed": 0, "failures": 0, "errors": 0, "skipped": 0}


def parse_report(path: str):
    """Return (counts, failed_names, skipped_names) for one TEST-*.xml file."""
    counts = _empty_counts()
    failed: list[str] = []
    skipped: list[str] = []
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:  # truncated report from a killed JVM
        counts["errors"] = 1
        counts["tests"] = 1
        failed.append(f"{os.path.basename(path)}#UNPARSEABLE_REPORT({exc})")
        return counts, failed, skipped

    cases = list(root.iter("testcase"))
    for case in cases:
        name = f"{case.get('classname', '')}#{case.get('name', '')}"
        counts["tests"] += 1
        if case.find("failure") is not None:
            counts["failures"] += 1
            failed.append(name)
        elif case.find("error") is not None:
            counts["errors"] += 1
            failed.append(name)
        elif case.find("skipped") is not None:
            counts["skipped"] += 1
            skipped.append(name)
        else:
            counts["passed"] += 1

    if not cases:
        # Suite-level problem without test cases (e.g. class initialisation crash that
        # surefire reports only in the suite attributes).
        suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
        for suite in suites:
            for key in ("tests", "failures", "errors", "skipped"):
                counts[key] += int(float(suite.get(key, "0") or 0))
        counts["passed"] = max(
            0, counts["tests"] - counts["failures"] - counts["errors"] - counts["skipped"])
        if counts["failures"] or counts["errors"]:
            failed.append(f"{os.path.basename(path)}#SUITE_LEVEL_FAILURE")
    return counts, failed, skipped


def collect_modules(root: str) -> dict:
    modules: dict[str, dict] = {}
    for dirpath, dirnames, _files in os.walk(root):
        # never descend into VCS data, node_modules, or nested report directories
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        if os.path.basename(dirpath) not in REPORT_DIRS:
            continue
        target_dir = os.path.dirname(dirpath)
        if os.path.basename(target_dir) != "target":
            continue
        module_dir = os.path.dirname(target_dir)
        rel = os.path.relpath(module_dir, root)
        rel = "." if rel == "." else rel.replace(os.sep, "/")
        mod = modules.setdefault(rel, {**_empty_counts(), "suites": 0,
                                       "failed_tests": [], "skipped_tests": []})
        for fname in sorted(os.listdir(dirpath)):
            if not (fname.startswith("TEST-") and fname.endswith(".xml")):
                continue
            counts, failed, skipped = parse_report(os.path.join(dirpath, fname))
            for key in COUNT_KEYS:
                mod[key] += counts[key]
            mod["suites"] += 1
            mod["failed_tests"].extend(failed)
            mod["skipped_tests"].extend(skipped)
    for mod in modules.values():
        mod["failed_tests"] = sorted(set(mod["failed_tests"]))
        mod["skipped_tests"] = sorted(set(mod["skipped_tests"]))
    return dict(sorted(modules.items()))


def totals(modules: dict) -> dict:
    out = {"modules_with_tests": 0, **_empty_counts()}
    for mod in modules.values():
        if mod["suites"]:
            out["modules_with_tests"] += 1
        for key in COUNT_KEYS:
            out[key] += mod[key]
    return out


def parse_reactor_logs(paths: list[str]) -> dict:
    failed, skipped, ok = [], [], 0
    for path in paths:
        if not os.path.isfile(path):
            continue
        # keep only the *last* "Reactor Summary" block of each log
        with open(path, errors="replace") as fh:
            lines = fh.read().splitlines()
        start = 0
        for i, line in enumerate(lines):
            if "Reactor Summary" in line:
                start = i
        for line in lines[start:]:
            m = REACTOR_RE.match(line)
            if not m:
                continue
            name, status = m.group(1).strip(), m.group(2)
            if status == "FAILURE":
                failed.append(name)
            elif status == "SKIPPED":
                skipped.append(name)
            else:
                ok += 1
    return {"success_modules": ok, "failed_modules": failed, "skipped_modules": skipped}


PLUGIN_RE = re.compile(r"--- (?:maven-)?(?:surefire|failsafe)[^ ]* .*@ (\S+) ---")
FORK_TIMEOUT = "There was a timeout or other error in the fork"


def find_fork_timeouts(paths: list[str]) -> list[str]:
    """Modules whose surefire/failsafe fork was killed by the fork timeout (hung tests).

    With -Dmaven.test.failure.ignore=true Maven reports BUILD SUCCESS for such a module, so the
    only trace is this log line; a hang must never be silently baked into the counts.
    """
    hits: list[str] = []
    for path in paths:
        if not os.path.isfile(path):
            continue
        module = "?"
        with open(path, errors="replace") as fh:
            for line in fh:
                m = PLUGIN_RE.search(line)
                if m:
                    module = m.group(1)
                elif FORK_TIMEOUT in line and module not in hits:
                    hits.append(module)
    return hits


TOOLCHAIN_RE = re.compile(r"(release version (\d+) not supported|invalid target release: (\S+)|"
                          r"Unsupported class file major version \d+)")


def find_toolchain_problem(paths: list[str]) -> str | None:
    """The build needs a newer JDK than the one used (e.g. a SNAPSHOT parent now sets release 21)."""
    for path in paths:
        if not os.path.isfile(path):
            continue
        with open(path, errors="replace") as fh:
            for line in fh:
                if line.startswith("[ERROR]"):
                    m = TOOLCHAIN_RE.search(line)
                    if m:
                        return ("compiler error '" + m.group(1) + "': the build requires a newer JDK than the one used "
                                "(Java release set by the parent POM / dependencies)")
    return None


def find_missing_artifacts(paths: list[str], limit: int = 5) -> list[str]:
    found: list[str] = []
    for path in paths:
        if not os.path.isfile(path):
            continue
        with open(path, errors="replace") as fh:
            for line in fh:
                if not line.startswith("[ERROR]"):
                    continue
                m = MISSING_ARTIFACT_RE.search(line)
                if m and m.group(1) not in found:
                    found.append(m.group(1)[:400])
                    if len(found) >= limit:
                        return found
    return found


def load_exclusions(path: str | None, repo: str) -> list:
    if not path or not os.path.isfile(path):
        return []
    with open(path) as fh:
        data = json.load(fh)
    return [dict(e) for e in data.get("exclusions", []) if e.get("repo") == repo]


def cmd_repo(args: argparse.Namespace) -> int:
    doc: dict = {"schema_version": SCHEMA_VERSION, "repo": args.repo}
    doc["jdk"] = {"version": args.jdk_version or "unknown", "select": args.jdk_select or "unknown"}
    doc["maven"] = args.maven_version or "unknown"
    if args.command:
        doc["commands"] = list(args.command)
    if args.exit_code:
        doc["build_exit_codes"] = [int(c) for c in args.exit_code]
    notes = list(args.note or [])

    if args.not_buildable:
        doc["status"] = "not_buildable"
        doc["reason"] = args.reason or "unspecified"
        missing = find_missing_artifacts(args.reactor_log or [])
        if missing:
            doc["missing_artifacts"] = missing
        doc["totals"] = {"modules_with_tests": 0, **_empty_counts()}
        doc["modules"] = {}
    else:
        modules = collect_modules(args.root)
        reactor = parse_reactor_logs(args.reactor_log or [])
        doc["modules"] = modules
        doc["totals"] = totals(modules)
        doc["reactor"] = reactor
        bad_exit = any(int(c) != 0 for c in (args.exit_code or []))
        if not modules:
            doc["status"] = "not_buildable"
            doc["reason"] = args.reason or find_toolchain_problem(args.reactor_log or []) \
                or "build produced no surefire reports"
            missing = find_missing_artifacts(args.reactor_log or [])
            if missing:
                doc["missing_artifacts"] = missing
        elif reactor["failed_modules"] or reactor["skipped_modules"] or bad_exit:
            doc["status"] = "partial"
            doc["reason"] = args.reason or (
                "reactor modules failed or were skipped: "
                + ", ".join(reactor["failed_modules"] + reactor["skipped_modules"]))
            missing = find_missing_artifacts(args.reactor_log or [])
            if missing:
                doc["missing_artifacts"] = missing
        else:
            doc["status"] = "ok"
        timeouts = find_fork_timeouts(args.reactor_log or [])
        if timeouts:
            doc["fork_timeouts"] = timeouts
            if doc["status"] == "ok":
                doc["status"] = "partial"
                doc["reason"] = args.reason or (
                    "surefire fork killed by the fork timeout (hung tests, results incomplete) in: "
                    + ", ".join(timeouts))
    for prior in args.prior_attempt or []:
        with open(prior) as fh:
            old = json.load(fh)
        doc.setdefault("prior_attempts", []).append({
            k: old[k] for k in ("jdk", "maven", "status", "reason", "missing_artifacts",
                                "build_exit_codes", "commands") if k in old})
    exclusions = load_exclusions(args.exclusions, args.repo)
    if exclusions:
        entries = []
        for ex in exclusions:
            ex.pop("repo", None)
            ex["test_classes"] = sorted(ex.get("test_classes", []))
            entries.append(ex)
            mod = doc["modules"].get(ex.get("module"))
            if mod is not None:
                mod["environment_excluded_classes"] = ex["test_classes"]
                # a class that was supposed to be excluded must not have produced a report
                ran = {n.split("#")[0] for n in mod["failed_tests"] + mod["skipped_tests"]}
                clash = sorted(ran & set(ex["test_classes"]))
                if clash:
                    notes.append("exclusion violated, classes produced results: " + ", ".join(clash))
        doc["environment_exclusions"] = sorted(entries, key=lambda e: (e.get("module", ""), e.get("category", "")))
    if notes:
        doc["notes"] = notes
    _dump(doc, args.out)
    t = doc["totals"]
    print(f"[parse_surefire] {args.repo}: status={doc['status']} modules_with_tests={t['modules_with_tests']} "
          f"tests={t['tests']} passed={t['passed']} failures={t['failures']} errors={t['errors']} "
          f"skipped={t['skipped']}", file=sys.stderr)
    return 0


def cmd_merge(args: argparse.Namespace) -> int:
    agg: dict = {}
    if args.update and os.path.isfile(args.out):
        with open(args.out) as fh:
            agg = json.load(fh)
    agg.setdefault("schema_version", SCHEMA_VERSION)
    agg["description"] = (
        "Pre-modernization unit-test baseline (JDK 17). Per-module surefire/failsafe counts "
        "parsed from target/*-reports/TEST-*.xml. Compare with compare_baseline.py.")
    repos = agg.setdefault("repos", {})
    for path in args.inputs:
        with open(path) as fh:
            doc = json.load(fh)
        repos[doc["repo"]] = {k: v for k, v in doc.items() if k not in ("repo", "schema_version")}
    agg["repos"] = dict(sorted(repos.items()))
    _dump(agg, args.out)
    return 0


def _dump(doc: dict, out: str | None) -> None:
    text = json.dumps(doc, indent=2, sort_keys=True) + "\n"
    if not out or out == "-":
        sys.stdout.write(text)
    else:
        with open(out, "w") as fh:
            fh.write(text)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("repo", help="parse one repo checkout")
    r.add_argument("--repo", required=True)
    r.add_argument("--root", required=True, help="repo checkout directory")
    r.add_argument("--out", help="output JSON file (default stdout)")
    r.add_argument("--jdk-version")
    r.add_argument("--jdk-select")
    r.add_argument("--maven-version")
    r.add_argument("--command", action="append", help="maven command line used (repeatable)")
    r.add_argument("--exit-code", action="append", help="exit code of each maven invocation (repeatable)")
    r.add_argument("--reactor-log", action="append", help="maven console log(s) to read the Reactor Summary from")
    r.add_argument("--not-buildable", action="store_true")
    r.add_argument("--reason")
    r.add_argument("--note", action="append")
    r.add_argument("--prior-attempt", action="append",
                   help="per-repo JSON of an earlier attempt on another JDK (e.g. the JDK 17 "
                        "not_buildable result) to embed as prior_attempts")
    r.add_argument("--exclusions", help="baseline-exclusions.json (environment exclusions per repo)")
    r.set_defaults(func=cmd_repo)

    m = sub.add_parser("merge", help="merge per-repo docs into an aggregate")
    m.add_argument("--out", required=True)
    m.add_argument("--update", action="store_true", help="keep repos already present in --out")
    m.add_argument("inputs", nargs="+")
    m.set_defaults(func=cmd_merge)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
