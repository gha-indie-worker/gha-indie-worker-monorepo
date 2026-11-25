#!/usr/bin/env python3
"""Fail-closed, source-only Gitlink/Zed lock provenance admission.

This checks *consistency*, not that a remote archive was downloaded, its digest
verified, or that zed/ores-compose materialization succeeded.
"""
from __future__ import annotations

import configparser
import re
import subprocess
import sys
import tomllib
from pathlib import Path

SHA = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")


def tree_gitlinks(raw: bytes) -> dict[str, str]:
    result: dict[str, str] = {}
    for record in raw.split(b"\0"):
        if not record:
            continue
        meta, sep, path = record.partition(b"\t")
        parts = meta.decode("ascii").split(" ")
        if not sep or len(parts) != 3:
            raise ValueError("invalid ls-tree record")
        mode, kind, oid = parts
        if mode != "160000":
            continue
        key = path.decode("utf-8")
        if kind != "commit" or not SHA.fullmatch(oid) or key in result:
            raise ValueError("invalid or duplicate gitlink")
        result[key] = oid
    return result


def modules_from_text(source: str) -> dict[str, str]:
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    parser.read_string(source)
    result: dict[str, str] = {}
    for section in parser.sections():
        if not section.startswith('submodule "') or not section.endswith('"'):
            raise ValueError("unexpected .gitmodules section")
        if set(parser[section]) != {"path", "url"}:
            raise ValueError("submodule must have only path and url")
        path = parser[section]["path"]
        url = parser[section]["url"]
        if not path or path in result:
            raise ValueError("duplicate or empty submodule path")
        result[path] = url
    return result


def verify(
    gitlinks: dict[str, str],
    modules_source: str,
    manifest_source: str,
    lock_source: str,
) -> list[str]:
    errors: list[str] = []
    try:
        modules = modules_from_text(modules_source)
        manifest = tomllib.loads(manifest_source)
        lock = tomllib.loads(lock_source)
    except (ValueError, configparser.Error) as exc:
        return [f"invalid metadata: {exc}"]

    if set(modules) != set(gitlinks):
        errors.append(".gitmodules paths do not exactly match HEAD gitlinks")
    for path, url in modules.items():
        if not path.startswith("apps/") or ".." in Path(path).parts:
            errors.append(f"unsupported submodule path: {path}")
        if not url.startswith("https://github.com/gha-indie-worker/") or not url.endswith(".git"):
            errors.append(f"unsupported or noncanonical submodule URL: {path}")

    entries = lock.get("git-submodule", [])
    if not isinstance(entries, list):
        return errors + ["lock git-submodule must be an array of tables"]
    work = manifest.get("workspace", {})
    members = work.get("members", []) if isinstance(work, dict) else []
    interop = manifest.get("interop", {})
    consume = (
        isinstance(interop, dict)
        and isinstance(interop.get("git"), dict)
        and interop["git"].get("consume_gitmodules") is True
    )
    if not isinstance(members, list) or any(not isinstance(x, str) for x in members):
        errors.append("workspace members must be an array of strings")
        members = []
    if len(set(members)) != len(members):
        errors.append("duplicate workspace member")
    if members and set(members) != set(gitlinks):
        errors.append("workspace members do not exactly match HEAD gitlinks")

    if not entries:
        if members or consume:
            errors.append("workspace declares materialization but has no git-submodule lock receipts")
        return errors

    if set(members) != set(gitlinks) or not consume:
        errors.append("materialized lock requires workspace members and consume_gitmodules=true")
    dependencies = manifest.get("dependencies", {})
    if not isinstance(dependencies, dict):
        errors.append("manifest dependencies must be a table")
        dependencies = {}

    seen: set[str] = set()
    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append(f"lock entry #{i} must be a table")
            continue
        path = entry.get("path")
        if not isinstance(path, str) or path in seen:
            errors.append(f"lock entry #{i}: duplicate or invalid path")
            continue
        seen.add(path)
        if entry.get("name") != path:
            errors.append(f"{path}: name and path mismatch")
        if entry.get("commit") != gitlinks.get(path):
            errors.append(f"{path}: lock commit differs from HEAD gitlink")
        if entry.get("url") != modules.get(path):
            errors.append(f"{path}: lock URL differs from .gitmodules")
        if entry.get("format") != "tar.gz":
            errors.append(f"{path}: unsupported source archive format")
        if not isinstance(entry.get("sha256"), str) or not DIGEST.fullmatch(entry["sha256"]):
            errors.append(f"{path}: invalid or missing archive digest")
        if not isinstance(entry.get("size"), int) or isinstance(entry["size"], bool) or entry["size"] <= 0:
            errors.append(f"{path}: invalid archive size")
        package = entry.get("package")
        if not isinstance(package, str) or dependencies.get(package) != f"={entry.get('version')}":
            errors.append(f"{path}: manifest dependency/version mismatch")
    if seen != set(gitlinks):
        errors.append("lock entries do not exactly match HEAD gitlinks")
    return errors


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    tree = subprocess.run(
        ["git", "ls-tree", "-r", "-z", "HEAD"],
        check=True, cwd=root, capture_output=True,
    ).stdout
    errors = verify(
        tree_gitlinks(tree),
        (root / ".gitmodules").read_text(),
        (root / ".zpkg.toml").read_text(),
        (root / ".zpkg.lock").read_text(),
    )
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    if errors:
        return 1
    print("PASS: exact HEAD gitlinks, .gitmodules, manifest and lock policy")
    print("NOTE: source-level metadata check, not actual archive or Zed materialization")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
