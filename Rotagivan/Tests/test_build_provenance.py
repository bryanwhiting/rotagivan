#!/usr/bin/env python3
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "build-provenance.py"


class BuildProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.source = self.repo / "Sources"
        self.source.mkdir()
        (self.source / "main.swift").write_text("let value = 1\n")
        self.template = self.repo / "Info.plist"
        self.template.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45"}))
        (self.repo / ".gitignore").write_text("build/\nYAML/.build/\n.signing/\n.DS_Store\n")
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Provenance fixture")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.output = self.repo / "build/Example.app/Contents/Info.plist"
        self.manifest = self.output.parent / "Resources/BuildProvenance.json"

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, check=True).stdout.decode().strip()

    def run_stamp(self, *extra, success=True, verify=False):
        args = ["python3", str(SCRIPT), "--repo", str(self.repo), "--manifest", str(self.manifest)]
        if verify:
            args += ["--verify"]
        else:
            args += ["--template", str(self.template), "--output", str(self.output), "--", str(self.source), *extra]
        result = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def metadata(self):
        return plistlib.loads(self.output.read_bytes())

    def test_clean_commit_numeric_fields_and_repeat_build(self):
        self.run_stamp()
        info = self.metadata()
        commit = self.git("rev-parse", "HEAD")
        self.assertEqual(info["RotagivanGitCommit"], commit)
        self.assertFalse(info["RotagivanGitDirty"])
        self.assertEqual(info["RotagivanDisplayVersion"], "v1.2.3-" + commit[:4])
        self.assertEqual(info["CFBundleShortVersionString"], "1.2.3")
        self.assertEqual(info["CFBundleVersion"], "45")
        self.run_stamp(verify=True)
        self.run_stamp()
        self.assertEqual(info["RotagivanSourceInputSHA256"], self.metadata()["RotagivanSourceInputSHA256"])
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_unstaged_and_staged_input_changes_are_dirty(self):
        path = self.source / "main.swift"
        path.write_text("let value = 2\n")
        self.run_stamp()
        info = self.metadata()
        self.assertTrue(info["RotagivanGitDirty"])
        self.assertTrue(info["RotagivanDisplayVersion"].endswith("-dirty"))
        self.git("add", str(path))
        self.run_stamp()
        self.assertEqual(info["RotagivanSourceInputSHA256"], self.metadata()["RotagivanSourceInputSHA256"])
        self.assertTrue(self.metadata()["RotagivanGitDirty"])

    def test_working_inputs_equal_head_are_clean_despite_index(self):
        path = self.source / "main.swift"
        path.write_text("let value = 2\n")
        self.git("add", str(path))
        path.write_text("let value = 1\n")
        self.run_stamp()
        self.assertFalse(self.metadata()["RotagivanGitDirty"])

    def test_untracked_build_input_is_dirty_and_changes_fingerprint(self):
        self.run_stamp()
        initial = self.metadata()["RotagivanSourceInputSHA256"]
        (self.source / "new.swift").write_text("let added = true\n")
        self.run_stamp()
        self.assertTrue(self.metadata()["RotagivanGitDirty"])
        self.assertNotEqual(initial, self.metadata()["RotagivanSourceInputSHA256"])

    def test_generated_outputs_and_unrelated_docs_do_not_make_inputs_dirty(self):
        for name in ["build/old-binary", "YAML/.build/cache", ".signing/public-cert", ".DS_Store", "docs/note.md"]:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("not an app source input\n")
        self.run_stamp()
        self.assertFalse(self.metadata()["RotagivanGitDirty"])

    def test_new_commit_changes_full_and_short_hash(self):
        self.run_stamp()
        old = self.metadata()
        (self.source / "main.swift").write_text("let value = 3\n")
        self.git("add", ".")
        self.git("commit", "-qm", "next")
        self.run_stamp()
        info = self.metadata()
        self.assertNotEqual(old["RotagivanGitCommit"], info["RotagivanGitCommit"])
        self.assertEqual(info["RotagivanDisplayVersion"], "v1.2.3-" + self.git("rev-parse", "HEAD")[:4])
        self.assertFalse(info["RotagivanGitDirty"])

    def test_build_input_or_head_change_during_build_is_rejected(self):
        self.run_stamp()
        (self.source / "main.swift").write_text("changed during compile\n")
        result = self.run_stamp(success=False, verify=True)
        self.assertIn("changed during compilation", result.stderr)
        self.git("checkout", "--", ".")
        self.run_stamp()
        self.git("commit", "--allow-empty", "-qm", "new head")
        self.run_stamp(success=False, verify=True)

    def test_missing_git_never_invents_provenance(self):
        self.run_stamp()
        (self.repo / ".git").rename(self.repo / "saved-git")
        self.output.unlink()
        result = self.run_stamp(success=False)
        self.assertIn("Git provenance is unavailable", result.stderr)
        self.assertFalse(self.output.exists())

    def test_generated_stamp_cannot_overwrite_a_build_input(self):
        self.output = self.template
        before = self.template.read_bytes()
        self.run_stamp(success=False)
        self.assertEqual(before, self.template.read_bytes())


if __name__ == "__main__":
    unittest.main()
