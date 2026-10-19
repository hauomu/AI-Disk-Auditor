#!/usr/bin/env bash

# AI Disk Auditor - Linux/macOS
# Read-only inventory of selected AI model, cache, and SDK directories.
# No files are created unless a report option is requested.

set +e

PROGRAM=${0##*/}
COMPREHENSIVE=false
REPORT_PATH=
LEGACY_REPORT=false
ROOTS=()
REQUESTED_ROOTS=()
PENDING_ROOTS=()
MODEL_ROOT=${AI_AUDIT_MODEL_ROOT:-}
STRATA_ROOT=${AI_AUDIT_STRATA_ROOT:-}
OS_NAME=$(uname -s 2>/dev/null)

usage() {
  cat <<EOF
Usage: $PROGRAM [options]
  -c, --comprehensive       Include selected system SDK and model roots
  -r, --report              Save to ~/AI-Disk-Audit-Reports/ai-disk-audit_TIMESTAMP.txt
      --report-path FILE    Write to a new report file (never overwrite)
  -h, --help                Show this help
      --root DIR            Add a scan root (repeatable)
      --model-root DIR      Add an AI model root
      --strata-root DIR     Add a Strata project root

The default scan is read-only and does not contact running services.
Environment: AI_AUDIT_MODEL_ROOT, AI_AUDIT_STRATA_ROOT, XDG_CACHE_HOME,
HF_HOME, HF_HUB_CACHE, HUGGINGFACE_HUB_CACHE, HF_XET_CACHE, HF_ASSETS_CACHE,
OLLAMA_MODELS, TORCH_HOME, PIP_CACHE_DIR, UV_CACHE_DIR, TRITON_CACHE_DIR,
CUDA_CACHE_PATH, ROCM_CACHE_DIR, HSA_CACHE_DIR, MIOPEN_USER_DB_PATH,
MIOPEN_CUSTOM_CACHE_DIR.
EOF
}

fail() { printf '%s: %s\n' "$PROGRAM" "$1" >&2; exit 2; }

add_root() { ROOTS[${#ROOTS[@]}]=$1; }

add_requested_root() {
  ROOTS[${#ROOTS[@]}]=$1
  REQUESTED_ROOTS[${#REQUESTED_ROOTS[@]}]=$1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -c|--comprehensive) COMPREHENSIVE=true; shift ;;
    -r|--report) LEGACY_REPORT=true; shift ;;
    --report-path)
      [ "$#" -ge 2 ] || fail "--report-path requires a file path"
      REPORT_PATH=$2; shift 2 ;;
    --report-path=*) REPORT_PATH=${1#*=}; [ -n "$REPORT_PATH" ] || fail "--report-path requires a file path"; shift ;;
    --root|--model-root|--strata-root)
      [ "$#" -ge 2 ] || fail "$1 requires a directory"
      case "$1" in
        --root) PENDING_ROOTS[${#PENDING_ROOTS[@]}]=$2 ;;
        --model-root) MODEL_ROOT=$2 ;;
        --strata-root) STRATA_ROOT=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1 (use --help)" ;;
  esac
done

if [ -z "$XDG_CACHE_HOME" ]; then XDG_CACHE_HOME="$HOME/.cache"; fi
if [ -z "$HF_HOME" ]; then HF_HOME="$XDG_CACHE_HOME/huggingface"; fi
if [ -z "$TRITON_CACHE_DIR" ]; then TRITON_CACHE_DIR="$HOME/.triton/cache"; fi

# Curated user locations; broad cache trees are intentionally not traversed.
add_root "$HOME/.ollama"
add_root "${OLLAMA_MODELS:-$HOME/.ollama/models}"
add_root "$HOME/.lmstudio/models"
add_root "$HOME/.continue"
add_root "$HF_HOME"
add_root "${HF_HUB_CACHE:-${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}}"
add_root "${HF_XET_CACHE:-$HF_HOME/xet}"
add_root "${HF_ASSETS_CACHE:-$HF_HOME/assets}"
add_root "${TORCH_HOME:-$XDG_CACHE_HOME/torch}"
add_root "${PIP_CACHE_DIR:-$XDG_CACHE_HOME/pip}"
add_root "${UV_CACHE_DIR:-$XDG_CACHE_HOME/uv}"
add_root "$TRITON_CACHE_DIR"
add_root "${CUDA_CACHE_PATH:-$HOME/.nv/ComputeCache}"
add_root "${ROCM_CACHE_DIR:-$XDG_CACHE_HOME/amd}"
if [ -n "$HSA_CACHE_DIR" ]; then add_root "$HSA_CACHE_DIR"; fi
add_root "${MIOPEN_CUSTOM_CACHE_DIR:-$XDG_CACHE_HOME/miopen}"
if [ -n "$MIOPEN_USER_DB_PATH" ]; then add_root "$MIOPEN_USER_DB_PATH"; fi
add_root "$XDG_CACHE_HOME/mlx"
add_root "$XDG_CACHE_HOME/llama.cpp"
add_root "$XDG_CACHE_HOME/llamacpp"
add_root "$XDG_CACHE_HOME/npm"
add_root "$XDG_CACHE_HOME/yarn"
add_root "$XDG_CACHE_HOME/pnpm"
add_root "$HOME/.cargo"
add_root "$HOME/.rustup"
add_root "$HOME/.conda"
add_root "$HOME/AI"
add_root "$HOME/Models"
add_root "$HOME/models"
add_root "$HOME/llm"
add_root "$HOME/LLM"
add_root "$HOME/ComfyUI/models"
add_root "$HOME/stable-diffusion-webui/models"
if [ "$OS_NAME" = Darwin ]; then
  add_root "$HOME/Library/Caches/mlx"
  add_root "$HOME/Library/Caches/com.apple.CoreML"
  add_root "$HOME/Library/Application Support/MLX"
  add_root "$HOME/Library/Application Support/CoreML"
  add_root "$HOME/Library/Application Support/llama.cpp"
  add_root "$HOME/Library/Caches/huggingface"
fi
add_root "$XDG_CACHE_HOME/huggingface"
add_root "$XDG_CACHE_HOME/ollama"
for ((i=0; i<${#PENDING_ROOTS[@]}; i++)); do add_requested_root "${PENDING_ROOTS[$i]}"; done
if [ -n "$MODEL_ROOT" ]; then add_requested_root "$MODEL_ROOT"; fi
if [ -n "$STRATA_ROOT" ]; then add_requested_root "$STRATA_ROOT"; fi

if [ "$COMPREHENSIVE" = true ]; then
  # Versioned SDK roots matter on Linux; include only relevant known locations.
  for p in /opt/rocm /opt/rocm/core-* /opt/rocm-* /usr/local/cuda /usr/local/cuda-* \
    /opt/intel /opt/intel/openvino /usr/local/share/ollama \
    /usr/share/ollama/.ollama/models /var/lib/ollama \
    "$HOME/.local/share/ollama" "$HOME/.local/share/LM Studio"; do
    add_root "$p"
  done
  if [ "$OS_NAME" = Darwin ]; then
    for p in "$HOME/Library/Caches/mlx" "$HOME/Library/Caches/com.apple.CoreML" \
      "$HOME/Library/Caches/com.apple.Metal" "$HOME/Library/Caches/huggingface" \
      "$HOME/Library/Application Support/MLX" "$HOME/Library/Application Support/CoreML" \
      "$HOME/Library/Application Support/llama.cpp" "$HOME/Library/Application Support/LM Studio" \
      "$HOME/Library/Developer/CoreSimulator/Caches" "$HOME/Library/Developer/Xcode/DerivedData"; do
      add_root "$p"
    done
  fi
fi
if [ "$LEGACY_REPORT" = true ] && [ -n "$REPORT_PATH" ]; then fail "use either --report or --report-path, not both"; fi

canonical_dir() (
  cd -P -- "$1" 2>/dev/null && printf '%s.' "$PWD"
)

allocated_kb() {
  # Linux and macOS du both support -x; never convert failures to 0.
  local out rc
  out=$(du -skx "$1" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$out" | awk 'NR==1 && $1 ~ /^[0-9]+$/ { print $1; ok=1 } END { if (!ok) exit 1 }'
}

scan() {
  printf 'AI Disk Auditor - Linux/macOS\n'
  printf 'Read-only directory inventory; no service calls or file changes.\n'
  if [ "$COMPREHENSIVE" = true ]; then printf 'Mode: comprehensive\n'; else printf 'Mode: quick\n'; fi
  printf '\nAllocated disk use by selected directory (GiB). Rows can overlap and are not additive.\n'
  printf '%-12s  %s\n' 'SIZE (GiB)' 'DIRECTORY'
  local i raw canonical kb gib status
  local j previous required escaped_raw escaped_path
  local seen=()
  local errors=0
  for ((i=0; i<${#ROOTS[@]}; i++)); do
    raw=${ROOTS[$i]}
    if [ ! -d "$raw" ]; then
      required=false
      for ((j=0; j<${#REQUESTED_ROOTS[@]}; j++)); do
        [ "${REQUESTED_ROOTS[$j]}" = "$raw" ] && required=true
      done
      if [ "$required" = true ]; then
        printf -v escaped_raw '%q' "$raw"
        printf 'ERROR       %s (requested directory not found)\n' "$escaped_raw"
        errors=$((errors+1))
      fi
      continue
    fi
    canonical=$(canonical_dir "$raw")
    if [ -z "$canonical" ]; then
      printf -v escaped_raw '%q' "$raw"
      printf 'ERROR       %s (cannot resolve directory)\n' "$escaped_raw"; errors=$((errors+1)); continue
    fi
    canonical=${canonical%.}
    required=false
    for ((j=0; j<${#seen[@]}; j++)); do
      previous=${seen[$j]}
      if [ "$previous" = "$canonical" ]; then
        printf -v escaped_raw '%q' "$raw"
        printf -v escaped_path '%q' "$canonical"
        printf 'ALIAS       %s -> %s\n' "$escaped_raw" "$escaped_path"
        required=true
        break
      fi
    done
    if [ "$required" = true ]; then continue; fi
    seen[${#seen[@]}]=$canonical
    kb=$(allocated_kb "$canonical"); status=$?
    if [ "$status" -ne 0 ] || [ -z "$kb" ]; then
      printf -v escaped_path '%q' "$canonical"
      printf 'ERROR       %s (du failed or scan was partial)\n' "$escaped_path"; errors=$((errors+1)); continue
    fi
    gib=$(awk -v k="$kb" 'BEGIN { printf "%.2f", k/1024/1024 }')
    printf -v escaped_path '%q' "$canonical"
    printf '%-12s  %s\n' "$gib" "$escaped_path"
  done
  printf '\nFilesystem and inode context:\n'
  if command -v df >/dev/null 2>&1; then df -h "$HOME" 2>&1; df -i "$HOME" 2>&1; else printf 'df unavailable\n'; fi
  if [ "$errors" -gt 0 ]; then printf '\nScan errors: %s. Reported rows may be incomplete.\n' "$errors"; fi
}

if [ "$LEGACY_REPORT" = true ]; then
  REPORT_DIR="$HOME/AI-Disk-Audit-Reports"
  mkdir -p "$REPORT_DIR" 2>/dev/null || fail "cannot create report directory: $REPORT_DIR"
  TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
  REPORT_PATH="$REPORT_DIR/ai-disk-audit_$TIMESTAMP.txt"
fi

if [ -n "$REPORT_PATH" ]; then
  if [ -e "$REPORT_PATH" ] || [ -L "$REPORT_PATH" ]; then
    fail "report destination already exists: $REPORT_PATH"
  fi
  # Bash noclobber opens a new report exclusively and prevents replacing existing files.
  (set -C; scan > "$REPORT_PATH") 2>/dev/null || fail "cannot create report (path exists or is not writable): $REPORT_PATH"
  cat "$REPORT_PATH"
  printf -v escaped_path '%q' "$REPORT_PATH"
  printf '\nReport saved to: %s\n' "$escaped_path"
else
  scan
fi
