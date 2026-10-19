# AI Disk Auditor notes

The Linux/macOS entry point remains the single standalone Bash file at
`linux/ai-disk-audit.sh`. It supports direct execution and streamed execution,
for example `bash <(curl -fsSL https://raw.githubusercontent.com/hauomu/AI-Disk-Auditor/main/linux/ai-disk-audit.sh)`.
It has no Python dependency, adjacent runtime files, installation step, or
download at runtime.

The scanner is read-only by default. It checks selected user AI/model/cache
locations, environment-configured locations, and optional system SDK/model
roots with `--comprehensive`. `--root` is repeatable; `--model-root` and
`--strata-root` accept custom directories and their `AI_AUDIT_*` environment
variables are honored. `--report` and `-r` keep the legacy timestamped report
location; `--report-path FILE` selects a new custom destination. Existing files
are refused. Sizes are allocated disk usage per directory row. Rows can overlap
and must not be added to claim a reclaimable total; hardlinks across separate
rows are not reconciled. Each selected root is physically resolved, duplicate
root aliases are scanned once, `du -x` excludes nested filesystems, and interior
symlinks are not followed. Errors stay visible rather than becoming zero.

No service APIs, sudo, secrets, broad temporary trees, broad Docker data, or
whole-cache recursion are used. `README.md` remains append-only per project
instructions; user-facing direction and implementation details belong here.

The fixture behavior checks live in `tests/test_ai_disk_audit.py`. They require
Python only as a development-host test orchestrator and Git Bash on Windows;
the auditor itself requires only Bash and standard utilities. All seven behavior
tests pass on native Linux (Artemis, GNU Bash 5.3.9). Windows Git Bash passes six
tests and skips the newline-path test. Native macOS/Bash 3.2 remains unverified.
