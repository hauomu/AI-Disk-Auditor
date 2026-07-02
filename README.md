# AI Disk Auditor

Find where your local AI models, SDKs, runtimes, and caches are using disk space.

AI Disk Auditor is a read-only utility for Windows, Linux, and macOS. It scans common local AI storage locations and prints a clear disk usage report so you can decide what to clean up manually.

## Project Goals

AI Disk Auditor is designed around five goals:

- Help users understand where Local AI software is using disk space.
- Provide actionable information without modifying the system.
- Support common Local AI ecosystems on Windows, Linux, and macOS.
- Remain lightweight, transparent, and easy to inspect.
- Follow native operating system conventions wherever possible.

## Safety

### Read-only Operation

- Does **not** delete files.
- Does **not** move files.
- Does **not** modify the registry.
- Does **not** change shell profiles.
- Does **not** install software.
- Does **not** unload running models.
- Does **not** stop services.
- Does **not** require administrator privileges for normal operation.

### Fail-safe Design

- Missing directories are skipped.
- Permission errors are skipped.
- Unsupported software is ignored.
- The script can be cancelled safely with `Ctrl+C`.

## Quick Start

### Windows

Download `windows/ai-disk-audit.ps1`, open PowerShell in that folder, then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\ai-disk-audit.ps1
```

Generate a text report:

```powershell
powershell -ExecutionPolicy Bypass -File .\ai-disk-audit.ps1 -Report
```

Run a deeper scan:

```powershell
powershell -ExecutionPolicy Bypass -File .\ai-disk-audit.ps1 -Comprehensive
```

### Linux / macOS

Download `linux/ai-disk-audit.sh`, open a terminal in that folder, then run:

```bash
chmod +x ./ai-disk-audit.sh
./ai-disk-audit.sh
```

Generate a text report:

```bash
./ai-disk-audit.sh --report
```

Run a deeper scan:

```bash
./ai-disk-audit.sh --comprehensive
```

## Features

### Read-only Audit

- Scans common Local AI directories.
- Calculates disk usage for detected folders.
- Reports model storage locations.
- Safe to cancel at any time with `Ctrl+C`.

### Scan Modes

#### Quick Scan

- Default mode.
- Optimized for everyday use.
- Scans the most common AI model, SDK, and cache locations.
- Completes quickly on most systems.

#### Comprehensive Scan

- Opt-in mode.
- Includes SDKs, compiler caches, temporary directories, and vendor-specific installation paths.
- May take several minutes depending on disk size.

### Report Generation

- Optional text report.
- Timestamped output.
- Useful for reviewing and cleaning your system later.
- Windows reports are saved under `%USERPROFILE%\AI-Disk-Audit-Reports`.
- Linux/macOS reports are saved under `~/AI-Disk-Audit-Reports`.

### Vendor Detection

- NVIDIA
- AMD
- Intel
- Qualcomm
- Apple Silicon / Metal / Core ML / MLX

### AI Runtime Detection

- Ollama
- Foundry Local
- LM Studio
- Hugging Face
- Continue
- AI Toolkit
- OpenVINO
- ONNX Runtime
- Docker
- Python
- Rust

## Supported Software

### Local LLM Platforms

- Ollama
- Foundry Local
- LM Studio

### AI Development Frameworks

- Hugging Face
- ONNX Runtime
- OpenVINO
- MLX
- Core ML

### Vendor SDKs and Runtimes

- NVIDIA CUDA
- AMD ROCm
- AMD Ryzen AI
- Intel OpenVINO
- Intel NPU Runtime
- Qualcomm AI Runtime
- Apple Metal / Core ML / MLX

### Development Toolchains

- Python
- Rust
- Docker
- Node package caches

## Design Principles

### Read-only First

- The utility never modifies the user's system.
- It provides information only.

### Fail Safely

- Any scan failure affects only the current directory.
- The remainder of the scan continues normally.

### Quick by Default

- Everyday scans should finish quickly.
- Comprehensive scanning is always opt-in.

### Transparency

- Every scanned directory is defined in the source code.
- No hidden downloads.
- No background services.
- No telemetry.

### Cross-platform

- Native PowerShell implementation for Windows.
- Native Bash implementation for Linux and macOS.

## FAQ

### Does this clean my computer automatically?

No. AI Disk Auditor is an auditor, not a cleaner. It helps you identify where space is being used so you can decide what to remove manually.

### Does this upload my files?

No. Everything runs locally.

### Does it require administrator privileges?

No for normal use. Some protected folders may be skipped if permissions are unavailable.

### Why does Comprehensive mode take longer?

Comprehensive mode includes broader SDK, cache, temp, vendor, and system locations. Some of those folders can be very large.

### Can I press Ctrl+C?

Yes. The tool is read-only, so cancelling it will not damage anything.

## Roadmap

- Duplicate model detection.
- Vendor-specific diagnostics.
- Model fingerprinting.
- Hugging Face cache analysis.
- Ollama cache analysis.
- Foundry Local diagnostics.
- Advisory-only cleanup recommendations.
- Future LocalAI Toolkit plugin architecture.

## License

MIT License.
