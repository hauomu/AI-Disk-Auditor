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
        for name in ("XDG_DATA_HOME", "HF_XET_CACHE", "HF_ASSETS_CACHE", "HUGGINGFACE_HUB_CACHE",
                     "TORCH_HOME", "PIP_CACHE_DIR", "UV_CACHE_DIR", "TRITON_CACHE_DIR", "CUDA_CACHE_PATH",
                     "HIP_CACHE_DIR", "ROCM_CACHE_DIR", "HSA_CACHE_DIR", "MIOPEN_CUSTOM_CACHE_DIR",
                     "MIOPEN_USER_DB_PATH", "CCACHE_DIR", "SCCACHE_DIR", "npm_config_cache", "BASH_ENV",
                     "HF_DATASETS_CACHE", "UV_PYTHON_INSTALL_DIR", "UV_TOOL_DIR", "VLLM_CACHE_ROOT"):
            self.env.pop(name, None)

    def run_script(self, args=(), stream=False, env=None):
        command = [BASH, "-s", "--", "--home-only", *args] if stream else [BASH, str(SCRIPT), "--home-only", *args]
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
        command = 'bash <(cat "$1") --home-only --root "$2"'
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
        self.assertIn("Resolved directory links:", output)
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
        self.assertIn("UNREADABLE", output)
        self.assertIn("could not be completely sized", output)

    def rows(self, output):
        return [line for line in output.splitlines()
                if any(status in line for status in ("  OK ", "  PARTIAL ", "  UNREADABLE "))]

    def test_server_workspaces_and_python_installations_are_discovered(self):
        for name in ("strata-stage1/prod/models", ".unsloth/venv", "ai/comfyui/.venv",
                     ".local/share/uv/python", ".cache/comgr"):
            directory = self.home / name
            directory.mkdir(parents=True)
            (directory / "fixture.bin").write_bytes(b"x" * 8192)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = "\n".join(self.rows(result.stdout.decode()))
        for name in ("strata-stage1", ".unsloth", "/ai", ".local/share/uv", ".cache/comgr"):
            self.assertIn(name, rows)

    def test_huggingface_is_sized_once_without_self_alias_or_nested_rows(self):
        hub = self.home / ".cache" / "huggingface" / "hub"
        hub.mkdir(parents=True)
        (hub / "blob.bin").write_bytes(b"x" * 16384)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = result.stdout.decode()
        hf_rows = [row for row in self.rows(output) if "huggingface" in row]
        self.assertEqual(len(hf_rows), 1, output)
        self.assertNotIn("/huggingface/hub", hf_rows[0])
        self.assertNotIn("Resolved directory links:", output)

    def test_shared_storage_discovers_ai_folders_without_sizing_unrelated_data(self):
        storage = self.base / "storage"
        for name in ("llm-nvme/models", "llm-nvme/hf-cache", "comfy-sata/comfyui/.venv", "other/photos"):
            directory = storage / name
            directory.mkdir(parents=True)
            (directory / "fixture.bin").write_bytes(b"x" * 8192)
        result = self.run_script(("--storage-root", bash_path(storage)))
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = "\n".join(self.rows(result.stdout.decode()))
        for name in ("llm-nvme/models", "llm-nvme/hf-cache", "comfy-sata/comfyui"):
            self.assertIn(name, rows)
        self.assertNotIn("photos", rows)
        self.assertNotIn("/other", rows)

    def test_partial_scan_retains_readable_size(self):
        hook = self.base / "partial-du.sh"
        hook.write_text('du() { printf "1048576\\t%s\\n" "$2"; return 1; }\n', encoding="utf-8", newline="\n")
        env = self.env.copy()
        env["BASH_ENV"] = bash_path(hook)
        result = self.run_script(("--root", bash_path(self.root)), env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.rows(result.stdout.decode())
        self.assertTrue(any("1.00" in row and "PARTIAL" in row for row in rows), rows)

    def test_sizes_are_sorted_largest_first(self):
        big = self.base / "big store"
        big.mkdir()
        (big / "weights.bin").write_bytes(b"x" * 2 * 1024 * 1024)
        result = self.run_script(("--root", bash_path(self.root), "--root", bash_path(big)))
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.rows(result.stdout.decode())
        big_index = next(i for i, row in enumerate(rows) if "big\\ store" in row)
        small_index = next(i for i, row in enumerate(rows) if "models\\ with\\ spaces" in row)
        self.assertLess(big_index, small_index)

    def test_missing_configured_root_and_empty_options_are_visible(self):
        result = self.run_script(("--root", bash_path(self.base / "missing")))
        self.assertIn(b"Missing/inaccessible", result.stdout)
        invalid = self.run_script(("--report-path", ""))
        self.assertNotEqual(invalid.returncode, 0)

    def test_unrelated_folders_do_not_exhaust_project_discovery(self):
        for i in range(240): (self.home/f'000-unrelated-{i:03}').mkdir()
        project=self.home/'vllm-portable-workspace'; project.mkdir()
        result=self.run_script(('--list-roots','--diagnostics'))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(b'vllm-portable-workspace',result.stdout)
        self.assertIn(b'traversals=0',result.stdout)

    def test_relocated_dataset_and_managed_python_install(self):
        dataset=self.base/'external-datasets'; dataset.mkdir()
        python=self.base/'managed-python'; python.mkdir()
        env=self.env.copy(); env['HF_DATASETS_CACHE']=bash_path(dataset); env['UV_PYTHON_INSTALL_DIR']=bash_path(python)
        result=self.run_script(('--list-roots',),env=env)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(b'external-datasets',result.stdout)
        self.assertIn(b'managed-python',result.stdout)

    def test_flat_root_planning_does_not_walk_files_or_probe_filesystems(self):
        peer=self.base/'another store'; peer.mkdir()
        result=self.run_script(('--root',bash_path(self.root),'--root',bash_path(peer),'--list-roots','--diagnostics'))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(b'traversals=0 filesystem_probes=0',result.stdout)

    def test_nested_roots_reuse_parent_device_identity(self):
        args=['--root',bash_path(self.root),'--list-roots','--diagnostics']
        for i in range(24):
            child=self.root/f'child-{i}'; child.mkdir()
            args.extend(['--root',bash_path(child)])
        result=self.run_script(args)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(b'traversals=0 filesystem_probes=25',result.stdout)


if __name__ == "__main__":
    unittest.main()
