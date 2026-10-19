# AI Disk Auditor notes

The Linux/macOS entry point remains the single standalone Bash file at
`linux/ai-disk-audit.sh`. It supports direct execution and streamed execution,
for example `bash <(curl -fsSL https://raw.githubusercontent.com/hauomu/AI-Disk-Auditor/main/linux/ai-disk-audit.sh)`.
It has no Python dependency, adjacent runtime files, installation step, or
download at runtime.

Quick mode checks model stores, download/compiler caches, named AI projects,
and environments. This includes LM Studio's downloaded runtimes, uv-managed
Python installations, Unsloth, Strata, llama.cpp, ComfyUI, vLLM and SGLang
workspaces. Named AI directories on shared storage below `/mnt`, `/media`,
`/srv`, and `/data` are discovered without scanning entire disks. Discovery
lists at most 200 child directories per parent, at bounded depth. It never
opens project files, service configuration, credentials or model contents.

`--comprehensive` additionally measures GPU SDKs (including versioned ROCm and
CUDA installations), toolchains and container data folders. Restricted paths
are reported without sudo or daemon queries. Quick mode still lists detected
tools/SDK locations without starting them. Filesystem capacity and inode
statistics cover the selected storage locations, not just the home disk.

`--root DIR` includes a specific directory; `--storage-root DIR` discovers named
AI folders below a storage parent. Both are repeatable. `--model-root` and
`--strata-root` override `AI_AUDIT_MODEL_ROOT` and `AI_AUDIT_STRATA_ROOT`.
`--home-only` disables automatic shared/system discovery; explicitly supplied
roots are still included. The scanner honors XDG cache/data locations and the
supported Hugging Face, Ollama, Torch, pip, uv, Triton and GPU compiler cache
environment variables. Use `--root` for arbitrary names or deeper layouts.

Reports are optional: `--report` / `-r` retain the timestamped report location;
`--report-path FILE` chooses a new destination. Existing paths are refused.
The largest directories appear first with category and status. Aliases are
resolved, identical targets are scanned once, and nested roots on the same
filesystem are included in their parent rather than listed again. Explicitly
selected children on different filesystems remain separate because `du -x`
excludes them from their parent. Interior symlinks are not traversed; selected
model-store/environment links are resolved as roots. Hard links across rows
may share storage, so rows are not additive or reclaimable totals. `PARTIAL`
retains readable bytes from an incomplete scan; `UNREADABLE` is not zero.

No service APIs, sudo, secrets, broad temporary trees, or whole-cache recursion
are used. Container data is measured only in comprehensive mode and may be
inaccessible. `README.md` remains append-only per project
instructions; user-facing direction and implementation details belong here.

The fixture behavior checks live in `tests/test_ai_disk_audit.py`. They require
Python only as a development-host test orchestrator and Git Bash on Windows;
the auditor itself requires only Bash and standard utilities. All 13 behavior
tests pass on native Linux (Artemis, GNU Bash 5.3.9). Windows Git Bash passes 12
tests and skips the newline-path case. A real read-only Artemis quick scan also
verifies shared-storage, Strata, Unsloth, uv and multi-filesystem coverage.
Native macOS/Bash 3.2 remains unverified.
