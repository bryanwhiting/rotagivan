#!/usr/bin/env python3
"""Stamp the built bundle from Git and the actual, explicitly listed build inputs."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


class ProvenanceError(Exception):
    pass


def git(repo, *args):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    result = subprocess.run(["git", "--no-optional-locks", "-C", str(repo), *args],
                            env=env, capture_output=True)
    if result.returncode:
        raise ProvenanceError("Git provenance is unavailable; build from a Git checkout with a valid HEAD.")
    return result.stdout


def snapshot(repo, roots):
    if Path(os.fsdecode(git(repo, "rev-parse", "--show-toplevel")).strip()).resolve() != repo:
        raise ProvenanceError("Build input root must be the Git repository root.")
    commit = git(repo, "rev-parse", "--verify", "HEAD^{commit}").decode().strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit):
        raise ProvenanceError("Git returned an invalid full commit hash.")
    files = set()
    for name in roots:
        path = repo / name
        if path.is_symlink() or not path.exists():
            raise ProvenanceError("Missing or symlinked build input: " + name)
        if path.is_dir():
            files.update(p for p in path.rglob("*") if p.is_file() or p.is_symlink())
        else:
            files.add(path)
    paths = sorted(p.relative_to(repo).as_posix() for p in files)
    entries = {}
    for record in git(repo, "ls-tree", "-rz", commit, "--", *paths).split(b"\0"):
        if record:
            header, name = record.split(b"\t", 1)
            mode, kind, oid = header.decode().split()
            entries[os.fsdecode(name)] = (mode, kind, oid)
    algorithm = "sha1" if len(commit) == 40 else "sha256"
    inputs = []
    dirty = False
    for name in paths:
        path = repo / name
        if path.is_symlink():
            raise ProvenanceError("Symlinked build input is unsupported: " + name)
        data = path.read_bytes()
        mode = "100755" if path.stat().st_mode & 0o111 else "100644"
        oid = hashlib.new(algorithm, b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        dirty |= entries.get(name) != (mode, "blob", oid)
        inputs.append({"path": name, "sha256": hashlib.sha256(data).hexdigest(), "mode": mode})
    digest = hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"commit": commit, "dirty": dirty, "inputSHA256": digest, "inputs": inputs}


def relative(repo, value):
    path = Path(os.path.abspath(value))
    # macOS exposes the same temp directory as /var/... and /private/var/....
    # Resolve parents while retaining the final component for the symlink check.
    path = path.parent.resolve() / path.name
    try:
        return path.relative_to(repo).as_posix()
    except ValueError:
        raise ProvenanceError("Build input must be inside the repository: " + str(path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--template", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("inputs", nargs="*")
    args = parser.parse_args()
    repo = args.repo.resolve()
    if args.verify:
        previous = json.loads(args.manifest.read_text())
        current = snapshot(repo, previous["inputRoots"])
        if any(current[key] != previous[key] for key in ["commit", "dirty", "inputSHA256"]):
            raise ProvenanceError("HEAD or build inputs changed during compilation. Rebuild before signing/installing.")
        print("Build provenance verified: HEAD and source inputs unchanged.")
        return
    if not args.template or not args.output or not args.inputs:
        parser.error("stamping requires --template, --output, and explicit build inputs")
    roots = sorted({relative(repo, value) for value in [str(args.template), *args.inputs]})
    for output in [args.output, args.manifest]:
        output_path = output.resolve()
        if any(output_path == repo / name or (repo / name).is_dir() and (repo / name) in output_path.parents
               for name in roots):
            raise ProvenanceError("Generated provenance must not overwrite or be included in build inputs.")
    captured = snapshot(repo, roots)
    info = plistlib.loads(args.template.read_bytes())
    version, build = info.get("CFBundleShortVersionString", ""), info.get("CFBundleVersion", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", build):
        raise ProvenanceError("macOS version and build must remain numeric fields.")
    display = "v" + version + "-" + captured["commit"][:4] + ("-dirty" if captured["dirty"] else "")
    captured.update({"formatVersion": 1, "inputRoots": roots, "version": version, "build": build,
                     "displayVersion": display,
                     "builtAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")})
    info.update({"RotaGitCommit": captured["commit"], "RotaGitDirty": captured["dirty"],
                 "RotaSourceInputSHA256": captured["inputSHA256"],
                 "RotaBuildDateUTC": captured["builtAtUTC"], "RotaDisplayVersion": display})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(plistlib.dumps(info, sort_keys=False))
    args.manifest.write_text(json.dumps(captured, indent=2) + "\n")
    print("Build provenance: " + display + " (" + build + ")\nGit commit: " + captured["commit"])


if __name__ == "__main__":
    try:
        main()
    except (ProvenanceError, OSError, ValueError, KeyError) as error:
        sys.exit("Build provenance error: " + str(error))
