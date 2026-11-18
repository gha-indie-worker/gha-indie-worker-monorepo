#!/usr/bin/env python3
"""Fail-closed, source-only gitlink contract for the public GHA Indie Worker monorepo.

Never resolve a floating branch/tag, rewrite a gitlink, or authenticate to a
different organization. Optional --materialized only reads already checked-out
submodules and confirms they match the indexed commit SHAs.
"""
from __future__ import annotations

import argparse
import configparser
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tomllib

REQUIRED_GITLINKS = frozenset({
    "apps/gha-indie-worker-api-server.rs",
    "apps/gha-indie-worker-web-server.rs",
})
OWNER = "gha-indie-worker"
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SUBMODULE_PATTERN = re.compile(r'^submodule "([^"]+)"$')


def git_output(*args: str) -> bytes:
    return subprocess.run(
        ["git", *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    ).stdout


def tracked_gitlinks(index: bytes) -> dict[str, str]:
    links: dict[str, str] = {}
    for raw in index.split(b"\0"):
        if not raw:
            continue
        try:
            metadata, path_bytes = raw.split(b"\t", 1)
            mode, sha_bytes, stage = metadata.decode("ascii").split()
            path = path_bytes.decode("utf-8")
        except (UnicodeError, ValueError) as error:
            raise ValueError("malformed git index entry") from error
        if mode != "160000":
            continue
        if stage != "0":
            raise ValueError(f"unmerged gitlink index stage for {path}")
        if path in links:
            raise ValueError(f"duplicate indexed gitlink: {path}")
        links[path] = sha_bytes
    return links


def validate(modules: str, links: dict[str, str], lock: str = "", package: str = "") -> list[str]:
    errors: list[str] = []
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    try:
        parser.read_string(modules)
    except configparser.Error as error:
        return [f"invalid .gitmodules: {error}"]

    declarations: dict[str, str] = {}
    for section in parser.sections():
        name = SUBMODULE_PATTERN.fullmatch(section)
        if not name:
            errors.append(f"unsupported .gitmodules section {section}")
            continue
        options = dict(parser.items(section))
        path = options.get("path", "")
        url = options.get("url", "")
        if set(options) != {"path", "url"}:
            errors.append(f"{section}: expected only path and url, never floating branch/update flags")
        if not path or path != name.group(1) or path in declarations:
            errors.append(f"{section}: mismatched, missing, or duplicate submodule path")
            continue
        parts = PurePosixPath(path).parts
        if len(parts) != 2 or parts[0] != "apps" or path != f"apps/{parts[1]}":
            errors.append(f"{section}: submodule path must be normalized and inside apps/")
            continue
        expected_url = f"https://github.com/{OWNER}/{parts[1]}.git"
        if url != expected_url:
            errors.append(f"{section}: submodule URL must equal {expected_url}")
        declarations[path] = url

    declared_paths = set(declarations)
    indexed_paths = set(links)
    if declared_paths != indexed_paths:
        errors.append(
            "declarations must equal tracked gitlinks: "
            f"untracked={sorted(declared_paths - indexed_paths)}; "
            f"undeclared={sorted(indexed_paths - declared_paths)}"
        )
    missing = REQUIRED_GITLINKS - declared_paths
    if missing:
        errors.append(f"missing mandatory API/web service gitlinks: {sorted(missing)}")
    for path, sha in links.items():
        if not SHA_PATTERN.fullmatch(sha) or sha == "0" * 40:
            errors.append(f"{path}: expected nonzero exact 40-character gitlink SHA")

    if lock:
        try:
            parsed_lock = tomllib.loads(lock)
        except tomllib.TOMLDecodeError as error:
            errors.append(f"invalid .zpkg.lock: {error}")
        else:
            records = parsed_lock.get("git-submodule", [])
            if not isinstance(records, list):
                errors.append(".zpkg.lock git-submodule must be an array")
            elif records:
                locked: set[str] = set()
                for entry in records:
                    if not isinstance(entry, dict):
                        errors.append("non-table git-submodule lock entry")
                        continue
                    path = entry.get("path")
                    if not isinstance(path, str) or path in locked:
                        errors.append("duplicate/invalid locked submodule path")
                        continue
                    locked.add(path)
                    if path not in links or entry.get("commit") != links[path]:
                        errors.append(f"{path}: .zpkg.lock commit does not match indexed gitlink")
                    if entry.get("url") != declarations.get(path):
                        errors.append(f"{path}: .zpkg.lock URL does not match .gitmodules")
                if locked != indexed_paths:
                    errors.append(".zpkg.lock submodule paths must equal indexed gitlinks")

    if package:
        try:
            parsed_package = tomllib.loads(package)
        except tomllib.TOMLDecodeError as error:
            errors.append(f"invalid .zpkg.toml: {error}")
        else:
            workspace = parsed_package.get("workspace", {})
            if workspace:
                members = workspace.get("members", [])
                if not isinstance(members, list) or any(not isinstance(x, str) for x in members):
                    errors.append("workspace members must be a list of paths")
                elif set(members) != indexed_paths or len(members) != len(indexed_paths):
                    errors.append("workspace members must equal indexed gitlinks")
    return errors


def main() -> int:
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--materialized", action="store_true")
    options = args.parse_args()
    try:
        links = tracked_gitlinks(git_output("ls-files", "--stage", "-z"))
        errors = validate(
            Path(".gitmodules").read_text(encoding="utf-8"),
            links,
            Path(".zpkg.lock").read_text(encoding="utf-8"),
            Path(".zpkg.toml").read_text(encoding="utf-8"),
        )
        if options.materialized:
            for path, expected in links.items():
                actual = git_output("-C", path, "rev-parse", "HEAD").decode("ascii").strip()
                if actual != expected:
                    errors.append(f"{path}: materialized {actual} != indexed {expected}")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        errors = [f"gitlink verification cannot proceed: {error}"]
    if errors:
        for error in errors:
            print(f"FAIL gitlink contract: {error}", file=sys.stderr)
        return 1
    print(f"PASS gitlink contract: {len(links)} exact indexed, authorized submodules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
