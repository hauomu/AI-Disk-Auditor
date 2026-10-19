# AI Disk Auditor: portable Windows and Linux refactor

The product goal is useful AI-storage coverage with low search/traversal cost
on different Windows and Linux installations, especially Linux LLM servers.
Artemis is one validation host; its folder names, hardware and timings are not
the specification. Defaults follow ecosystem conventions and environment
overrides. Arbitrary locations remain available through explicit roots.

## Existing script-block workflows

Windows PowerShell 5.1 / PowerShell 7 on Windows:

```powershell
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/hauomu/AI-Disk-Auditor/main/windows/ai-disk-audit.ps1")))
```

Linux Bash (the macOS entry point is retained):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hauomu/AI-Disk-Auditor/main/linux/ai-disk-audit.sh)
```

Both scripts remain standalone. There are no adjacent runtime files, third-party
packages, install steps, default daemon queries, or cleanup actions.

## Coverage and search cost

- Windows uses profile/AppData/ProgramData/ProgramFiles locations supplied by the
  operating environment, and checks fixed-drive roots for named AI directories.
  It does not assume models live on `C:` and does not enumerate all drive trees.
- Linux uses XDG cache/data conventions, standard model stores, shallow project
  discovery and shared-storage parents. Broad temporary/cache trees are excluded.
  Unrelated directory names no longer exhaust its project-discovery budget.
  Actual discovery limits are reported when reached. macOS adds `/Volumes`.
- Both honor supported relocated Hugging Face, Ollama, uv, Torch and compiler
  cache roots. uv's platform locations follow its [storage reference](https://docs.astral.sh/uv/reference/storage/):
  Windows cache is under LocalAppData, and managed Python is under Roaming
  AppData. Explicit uv cache/Python/tool overrides take precedence.
- [Hugging Face dataset caches](https://huggingface.co/docs/datasets/cache)
  and custom vLLM cache roots can be separate from model download storage.
- Roots are canonicalized and deduplicated before recursive measurements.
  Covered child roots are removed. Explicit root links are resolved; interior
  links/junctions are skipped so they cannot create traversal loops.
- Linux queries filesystem identity only when roots overlap and caches each
  result. Separately mounted children remain visible because `du -x` excludes
  them from their parents. Flat roots need no identity probes.
- Windows traverses cached filesystem metadata in a built-in .NET enumerator,
  avoiding a PowerShell provider/pipeline operation per file. A provider fallback
  handles unavailable native compilation. No background service or helper DLL
  needs installing. It does not invoke Ollama/Foundry or launch Notepad.

## Scope and diagnostics

Windows adds `-Root`, `-StorageRoot`, `-ModelRoot`, `-StrataRoot`, `-HomeOnly`,
`-ListRoots`, `-Diagnostics`, and `-ReportPath`. Existing `-Comprehensive` and
`-Report` remain valid. Linux has the corresponding kebab-case options such as
`--root`, `--storage-root`, `--home-only`, `--list-roots`, and `--diagnostics`.

List-roots mode performs no recursive size measurements. Use it to inspect
coverage before a full audit. Diagnostics exposes root/traversal counts; it is
also used to test that duplicate roots do not cause duplicate walks. Home-only
mode skips automatic shared/system discovery, while explicit roots still apply.

Comprehensive mode adds SDKs, toolchains and container data directories; it
never contacts container daemons or elevates privileges. Permission failures
remain visible. Unknown application names or deeper layouts need explicit roots.

## Report semantics

Results are sorted largest first and marked OK, PARTIAL or UNREADABLE as
appropriate. Windows sums apparent file lengths per directory entry; hard links
can count repeatedly. Linux reports allocated blocks through `du`, which
deduplicates hard links within each invocation. These measures differ, and
neither is an aggregate reclaimable-byte estimate. Cross-row sharing is not
reconciled. Missing/inaccessible configured roots are reported.

Reports are optional and refuse existing destinations. `-Report` / `--report`
retain the timestamped `AI-Disk-Audit-Reports` directory. Custom report-path
options choose a new file. Scanned application data and settings are never written.

## Validation and limits

Tests cover varied fixture layouts: redirected model/dataset/cache/runtime
paths, secondary storage, literal paths, aliases, link cycles, nested roots,
more than 200 unrelated directories, partial scans and report collisions.
Native Linux passes 17 cases. Windows passes six PowerShell behavior cases,
including script-block execution in Windows PowerShell 5.1 and PowerShell 7.
Native macOS/Bash 3.2 and additional Windows/Linux OS versions are unverified.

A warm synthetic 10,000-file Windows cache-tree comparison returns identical
counts/bytes: median 513 ms for the previous provider pipeline and 14 ms for
the metadata enumerator (three repetitions). This isolates enumeration cost;
it does not promise a fixed whole-audit speedup on other disks or machines.

The existing `README.md` remains unchanged under its append-only rule.
