# Security Policy

## Security Philosophy

AI Disk Auditor is designed as a read-only auditing utility. Its primary purpose is to help users understand where local AI software, models, SDKs, runtimes, and caches are consuming disk space. It is intentionally designed to observe rather than modify.

## What the Project Will Never Do

- Upload telemetry.
- Collect personal information.
- Send scan results to external services.
- Download executables during a scan.
- Execute remote code.
- Modify Windows Registry settings.
- Change shell profiles or environment variables.
- Install or uninstall software.
- Stop services or background processes.
- Unload running AI models.
- Delete, move, or modify user files.

## Safety Principles

- Read-only by default.
- Fail safely when directories are inaccessible.
- Skip missing folders without error.
- Continue scanning even if individual paths fail.
- Safe to interrupt using Ctrl+C.

## Transparency

Every directory scanned by AI Disk Auditor is explicitly defined in the source code. The project does not use hidden downloads, background services, or obfuscated code.

## Future Features

If future versions introduce optional cleanup or maintenance tools, they will remain opt-in, clearly documented, and separate from the default read-only audit mode.
