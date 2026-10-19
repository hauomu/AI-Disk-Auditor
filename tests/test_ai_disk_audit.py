"""Development-host behavior checks for the standalone Bash auditor."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "linux" / "ai-disk-audit.sh"
BASH = os.environ.get("AI_AUDIT_BASH") or shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe"


def bash_path(path: Path) -> str:
    """Translate a Windows path for Git Bash; leave POSIX paths alone."""
    value = str(path)
    if len(value) > 2 and value[1:3] == ":\\":
        return "/" + value[0].lower() + "/" + value[3:].replace("\\", "/")
    return value


class AuditorBehavior(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="ai-audit-", dir=REPO.parent))
        self.home = self.base / "home with spaces"
        self.home.mkdir()
        self.root = self.base / "models with spaces"
        self.root.mkdir()
        (self.root / "model-☃.bin").write_bytes(b"model data" * 4096)
        self.torch_cache = self.home / ".cache" / "torch"
        self.torch_cache.mkdir(parents=True)
        self.env = os.environ.copy()
        self.env.update({"HOME": bash_path(self.home), "XDG_CACHE_HOME": bash_path(self.home / ".cache")})
        for name in ("AI_AUDIT_MODEL_ROOT", "AI_AUDIT_STRATA_ROOT", "OLLAMA_MODELS", "HF_HOME", "HF_HUB_CACHE"):
            self.env.pop(name, None)

    def run_script(self, args=(), stream=False, env=None):
        command = [BASH, "-s", "--", *args] if stream else [BASH, str(SCRIPT), *args]
        source = SCRIPT.read_bytes() if stream else None
        return subprocess.run(command, input=source, capture_output=True, env=env or self.env, text=False)

    def test_local_and_stream_invocation_scan_paths_and_no_default_report(self):
        for stream in (False, True):
            result = self.run_script(("--root", bash_path(self.root), "--model-root", bash_path(self.root)), stream)
            output = result.stdout.decode(errors="replace")
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertIn("allocated", output.lower())
            self.assertIn("models\\ with\\ spaces", output)
            self.assertIn(".cache/torch", output)
            self.assertIn("not additive", output.lower())
            self.assertNotIn("model-☃.bin", output)
        self.assertEqual(list(self.base.rglob("*.txt")), [])

    def test_process_substitution_invocation(self):
        command = 'bash <(cat "$1") --root "$2"'
        result = subprocess.run(
            [BASH, "-c", command, "process-substitution", bash_path(SCRIPT), bash_path(self.root)],
            capture_output=True,
            env=self.env,
        )
        output = result.stdout.decode(errors="replace")
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertIn("models\\ with\\ spaces", output)
        self.assertIn("not additive", output.lower())

    def test_environment_roots_and_symlink_alias_are_handled(self):
        alias = self.base / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        env = self.env.copy()
        env["AI_AUDIT_MODEL_ROOT"] = bash_path(self.root)
        env["AI_AUDIT_STRATA_ROOT"] = bash_path(alias)
        result = self.run_script(("--root", bash_path(self.root),), env=env)
        output = result.stdout.decode(errors="replace")
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertIn("ALIAS", output)
        self.assertIn("models\\ with\\ spaces", output)

    @unittest.skipIf(os.name == "nt", "Git Bash on Windows cannot reliably pass newline paths through CreateProcess argv")
    def test_newline_in_root_path_is_quoted(self):
        newline_root = bash_path(self.base) + "/models\nwith-newline"
        created = subprocess.run([BASH, "-c", 'mkdir -p -- "$1"', "fixture", newline_root], capture_output=True)
        self.assertEqual(created.returncode, 0, created.stderr.decode(errors="replace"))
        env = self.env.copy()
        env["AI_AUDIT_MODEL_ROOT"] = newline_root
        result = self.run_script(env=env)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertIn(b"models\\nwith-newline", result.stdout)

    def test_report_is_explicit_and_refuses_overwrite(self):
        report = self.base / "audit output.txt"
        args = ("--root", bash_path(self.root), "--report-path", bash_path(report))
        first = self.run_script(args)
        self.assertEqual(first.returncode, 0, first.stderr.decode(errors="replace"))
        self.assertTrue(report.exists())
        original = report.read_bytes()
        second = self.run_script(args)
        self.assertNotEqual(second.returncode, 0)
        self.assertEqual(report.read_bytes(), original)
        directory_result = self.run_script(("--root", bash_path(self.root), "--report-path", bash_path(self.root)))
        self.assertNotEqual(directory_result.returncode, 0)
        self.assertIn(b"already exists", directory_result.stderr)

    def test_legacy_report_flags_work_without_arguments(self):
        for index, flag in enumerate(("--report", "-r")):
            home = self.base / ("legacy home " + str(index))
            home.mkdir()
            env = self.env.copy()
            env["HOME"] = bash_path(home)
            args = (flag, "--root", bash_path(self.root))
            if flag == "--report":
                args = ("--comprehensive", flag, "--root", bash_path(self.root))
                fake_commands = self.base / "fake-commands.sh"
                fake_commands.write_text("du() { echo partial >&2; return 1; }\n", encoding="utf-8", newline="\n")
                env["BASH_ENV"] = bash_path(fake_commands)
            result = self.run_script(args, env=env)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            report_dir = home / "AI-Disk-Audit-Reports"
            reports = list(report_dir.glob("ai-disk-audit_*.txt"))
            self.assertEqual(len(reports), 1)
            self.assertIn(b"AI Disk Auditor", reports[0].read_bytes())

    def test_help_and_bad_du_are_visible(self):
        help_result = self.run_script(("--help",))
        self.assertEqual(help_result.returncode, 0)
        self.assertIn(b"--comprehensive", help_result.stdout)
        fake_commands = self.base / "fake-commands.sh"
        fake_commands.write_text("du() { echo partial >&2; return 1; }\n", encoding="utf-8", newline="\n")
        env = self.env.copy()
        env["BASH_ENV"] = bash_path(fake_commands)
        result = self.run_script(("--root", bash_path(self.root)), env=env)
        output = result.stdout.decode(errors="replace")
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertIn("ERROR", output)
        self.assertIn("incomplete", output.lower())


if __name__ == "__main__":
    unittest.main()
