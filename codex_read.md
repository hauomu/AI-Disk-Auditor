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

## Model identity inventory (2026-10-20)

The original pre-session baseline (`136d83f`) listed Ollama models and Windows
Foundry caches. The first refactors removed those listings and overemphasized
directory sizes. Both standalone scripts now inventory files by default within
the discovered/selected roots, retaining the existing curl/PowerShell script-block
entry points. No separate backend or neighboring runtime files are required.

- Models: path, apparent file length, format, weights/projector/MTP/n-gram role,
  model name, architecture, quantization, declared author/organization and quantizer.
- Evidence: GGUF headers, safetensors descriptors and adjacent standard model
  `config.json` metadata, offline Ollama manifest references, HF/LM Studio paths.
  Repository/uploader is separate from declared author. Filename roles and quants
  are labeled inferred; no universal MTP/n-gram signature is claimed.
- Runtime and gateway candidates: separate sections for CUDA, ROCm/HIP, Vulkan,
  Metal/MLX, DirectML, GGML/inference libraries and gateway/frontend code paths.
  Presence does not prove a backend is loaded or a service running. Tests/examples
  are excluded from gateway matching; arbitrary filenames still need `--root`.
- Split GGUF files missing identity fields may inherit them from the first shard;
  the report explicitly identifies this source. No tensor validation occurs.
- Linux uses an embedded optional Python 3 stdlib reader. Without installed
  Python it still inventories filename candidates, with unknown header fields.
  Windows enriches candidates collected during its existing .NET traversal;
  restricted environments without Add-Type get a filename-only provider fallback.
- Controls: `--no-inventory` / `-NoInventory`, `--model-limit N` / `-ModelLimit N`
  (default 500), `--gateway-root DIR` / `-GatewayRoot DIR` and
  `AI_AUDIT_GATEWAY_ROOT`. Planning mode never inspects headers.

Metadata work is bounded: GGUF positions at most 256 MiB, at most 100,000 keys
and 2,000,000 array elements/steps; safetensors headers at most 8 MiB and model
JSON at most 1 MiB. No hashing, tensor loading, model startup, configuration
execution or gateway secret reads. Linux skips dependency/test trees and caps
file inspection at 300,000 entries; Windows caps retained candidates per kind
per root at 10,000. Limits and unsupported/malformed metadata are explicit.
These bounds can leave fields unknown. Discovery is not a whole-disk search.

Binary fixture tests cover little/big endian GGUF, large skipped arrays,
conflicting header/filename quants, shard identity inheritance, mmproj/MTP/ngram,
safetensors/config metadata, offline Ollama blobs, runtime/gateway candidates,
corrupt headers and inventory opt-out. Native Linux passes 20 total cases;
Windows passes its six traversal cases and two model-metadata cases.
Native macOS remains unverified. A read-only Artemis sample identified actual
projectors/MTP files and header Q6_K/Q5_K_M/Q8_0/Q4_K_M/F16 quants. One file
named `mtp-Qwen3.8-27B-Q4_0.gguf` declares Q4_K_S, demonstrating why the report
keeps filename hints separate. Per-file apparent lengths can exceed allocated
directory usage for sparse files.

Format references: [GGUF specification](https://github.com/ggml-org/ggml/blob/master/docs/gguf.md),
[llama.cpp metadata/file-type constants](https://github.com/ggml-org/llama.cpp/blob/master/gguf-py/gguf/constants.py),
and [Ollama model manifest handling](https://github.com/ollama/ollama/blob/main/server/images.go).

## Group sharded models in reports

The default inventory now reports one model set for numbered
`NAME-00001-of-000NN.gguf`, `.safetensors` and `.bin` files in the same directory.
Different directory paths, prefixes, quantization names, total counts and formats
remain separate. Projectors and MTP sidecars are not combined with base weights.
Each set reports its filename pattern, discovered/expected count, missing indices,
combined apparent size and one representative header file. Header parsing selects
the lowest available shard; model limits and sorting apply after grouping.
Filename completeness means the numbered parts were discovered, not that tensors
or shard contents are valid. Sizes include only discovered parts; metadata and
identity fields are not verified on every shard. Unnumbered files remain individual.

Filename-only Linux fallback also groups shards and reports missing parts, but
cannot provide combined sizes/header identity; Windows provider fallback groups
and sums sizes without header identity. Fallback row limits retain their existing
restrictions. Standard five-digit split naming is supported; arbitrary naming
schemes and index-manifest-only shard associations are not guessed.

Validation: native Linux 22 passed plus one Windows-only skip; Windows model suite
five passed plus one Unix-only skip. Added checks cover group size/ranking before
limits, missing parts, separate directories, safetensors sets, separate projectors
and both dependency-restricted fallbacks. Existing script-block workflow remains.

## Remove package-data and gateway false positives

The user's Windows report revealed SciPy/Matplotlib NPZ data files and Python
`.pth` loaders mislabeled as weights, vocabulary GGUFs mislabeled as models, and
cached dependency proxy modules mislabeled as gateways. Inventory classification
now excludes test/example/sample trees, requires a model-like basename for NPZ
candidates outside dependency stores, excludes Python package `.pth` loaders, and
classifies `ggml-vocab-*.gguf` separately as tokenizer/vocabulary assets.

Generic proxy filenames do not imply an AI gateway. Gateway candidate names must
identify a gateway/frontdoor/LiteLLM/OpenAI server, or reside in a known/explicit
gateway root; dependency caches and environment packages do not qualify. Explicit
gateway hints survive parent-root deduplication. Directory sizing is unchanged;
these exclusions apply to file identity, not storage accounting.

Runtime libraries and vocabulary assets are summarized by containing installation
directory (LM Studio backend/version directories are recognized), with count,
combined apparent size, detected backend families and at most three example names.
Different runtime installations/versions remain visible. These are path-derived
installation candidates, not proof of active backend use. Known vocabulary naming
is separated without claiming universal tokenizer detection. The Windows scanner
types are versioned so repeated script-block runs cannot reuse an older classifier.

Validation: Linux 25 passed plus one Windows-only skip; Windows model/classification
suite eight passed plus one Unix-only skip, and six traversal fixtures passed.
A path-only replay of the user's 680 reported entries excludes 556 false-positive
candidates, retains five model candidates, separates 19 vocabulary assets and
retains 100 reported backend files for grouped presentation. This replay opens no
AppData/model files and does not claim those five candidates have verified contents.
Sharded-model grouping remains covered. Changes are in the same pending PR #5.
