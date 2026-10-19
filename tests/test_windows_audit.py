"""Portable Windows layouts and traversal budgets; no real AppData scans."""
import base64
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'windows' / 'ai-disk-audit.ps1'
ENGINES = list(dict.fromkeys(p for p in (shutil.which('powershell'), shutil.which('pwsh'), os.environ.get('AI_AUDIT_PWSH')) if p))

def quoted(value):
    return "'" + str(value).replace("'", "''") + "'"

@unittest.skipUnless(os.name == 'nt' and ENGINES, 'Requires native Windows PowerShell')
class WindowsAudit(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix='windows-audit-layout-', dir=REPO.parent))
        self.profile = self.base / 'profile'
        self.profile.mkdir()
        self.env = os.environ.copy()
        prefixes=('AI_AUDIT_', 'HF_', 'HUGGINGFACE_', 'UV_', 'TORCH_', 'CUDA_', 'TRITON_', 'VLLM_', 'OLLAMA_', 'XDG_')
        for key in list(self.env):
            if key.startswith(prefixes): self.env.pop(key)
        for key, directory in [('USERPROFILE','profile'),('LOCALAPPDATA','local'),('APPDATA','roaming'),
                               ('ProgramData','program-data'),('ProgramFiles','program-files'),('TEMP','temp'),('TMP','temp')]:
            folder = self.base / directory
            folder.mkdir(exist_ok=True)
            self.env[key] = str(folder)

    def run_audit(self, args='', engine=None, prefix=''):
        command = ("[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); " + prefix +
                   "& ([scriptblock]::Create([IO.File]::ReadAllText("+quoted(SCRIPT)+"))) -HomeOnly -Diagnostics "+args)
        encoded=base64.b64encode(command.encode('utf-16le')).decode('ascii')
        return subprocess.run([engine or ENGINES[0],'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
                               '-EncodedCommand',encoded],env=self.env,capture_output=True,encoding='utf-8',timeout=60)

    def store(self, name, count=1):
        root=self.base/name
        root.mkdir(parents=True)
        for i in range(count): (root/f'weights-{i}.bin').write_bytes(b'x'*4096)
        return root

    def test_script_block_both_engines_and_one_walk_for_nested_roots(self):
        parent=self.store('store [literal]',2)
        child=parent/'nested'; child.mkdir(); (child/'third.bin').write_bytes(b'abc')
        args='-Root '+quoted(parent)+','+quoted(child)+','+quoted(parent)
        for engine in ENGINES:
            with self.subTest(engine=engine):
                result=self.run_audit(args,engine)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('traversals=1 files=3',result.stdout)
                self.assertIn('scanner=dotnet',result.stdout)
                self.assertFalse(list(self.profile.glob('AI-Disk-Audit-Reports/*')))

    def test_relocated_hf_uv_and_python_paths(self):
        for var, name in [('HF_HOME','redirected-hf'),('UV_CACHE_DIR','redirected-uv'),('UV_PYTHON_INSTALL_DIR','python-runtime')]:
            self.env[var]=str(self.store(name))
        result=self.run_audit('-ListRoots')
        self.assertEqual(result.returncode,0,result.stderr)
        for name in ('redirected-hf','redirected-uv','python-runtime'): self.assertIn(name,result.stdout)
        self.assertIn('traversals=0',result.stdout)

    def test_secondary_storage_and_unknown_volume_name(self):
        root=self.store('secondary-volume/inference/models')
        result=self.run_audit('-StorageRoot '+quoted(self.base/'secondary-volume')+' -ListRoots')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(str(root),result.stdout)

    def test_explicit_root_links_are_deduplicated_and_interior_links_skipped(self):
        root=self.store('source-data',2)
        alias=self.base/'alias'; alias.symlink_to(root,target_is_directory=True)
        (root/'loop').symlink_to(root,target_is_directory=True)
        result=self.run_audit('-Root '+quoted(root)+','+quoted(alias))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('traversals=1 files=2',result.stdout)
        self.assertIn('Skipped interior reparse points: 1',result.stdout)

    def test_relative_roots_and_report_refusal(self):
        root=self.store('relative-store')
        prefix='Set-Location -LiteralPath '+quoted(self.base)+'; '
        first=self.run_audit('-Root '+quoted('.\\relative-store')+' -ReportPath '+quoted('.\\audit.txt'),prefix=prefix)
        self.assertEqual(first.returncode,0,first.stderr)
        report=self.base/'audit.txt'; original=report.read_bytes()
        second=self.run_audit('-Root '+quoted(root)+' -ReportPath '+quoted(report))
        self.assertNotEqual(second.returncode,0)
        self.assertEqual(report.read_bytes(),original)

    def test_missing_path_is_visible(self):
        result=self.run_audit('-Root '+quoted(self.base/'not-here')+','+quoted(self.profile/'.ollama')+' -ListRoots')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('Missing/inaccessible',result.stdout)
        self.assertIn('.ollama',result.stdout)

if __name__ == '__main__': unittest.main()
