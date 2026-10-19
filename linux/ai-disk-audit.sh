#!/usr/bin/env bash
# AI Disk Auditor: standalone, read-only Linux/macOS storage inventory.
# Bash 3.2 compatible. Only explicit report options create files.
set +e

COMPREHENSIVE=false
HOME_ONLY=false
LEGACY_REPORT=false
REPORT_PATH=
MODEL_ROOT=${AI_AUDIT_MODEL_ROOT:-}
STRATA_ROOT=${AI_AUDIT_STRATA_ROOT:-}
OS_NAME=$(uname -s 2>/dev/null)
PATHS=(); GROUPS_LIST=(); LABELS=(); REQUIRED=()
CUSTOM_ROOTS=(); STORAGE_ROOTS=()
SELECTED_PATHS=(); SELECTED_GROUPS=(); SELECTED_LABELS=()
ALIASES=(); ISSUES=()
COVERED=0

usage() {
  cat <<'EOF'
AI Disk Auditor - Linux/macOS
Usage: bash ai-disk-audit.sh [options]
  -c, --comprehensive    Also measure SDKs, toolchains and container data folders
  -r, --report           Save a new timestamped report in ~/AI-Disk-Audit-Reports
      --report-path FILE Save to a custom new file; existing paths are refused
      --root DIR         Include a directory (repeatable)
      --model-root DIR   Include a custom model store (or AI_AUDIT_MODEL_ROOT)
      --strata-root DIR  Include a Strata workspace (or AI_AUDIT_STRATA_ROOT)
      --storage-root DIR Look for AI folders below a storage parent (repeatable)
      --home-only        Skip automatic system/shared-storage discovery
  -h, --help             Show this help

Quick mode includes known model/cache locations, named AI projects, Python
environments and AI directories on shared storage. Discovery examines directory
names at bounded depth; it never reads model contents, secrets or service config.
No cleanup, sudo, daemon calls, installation or adjacent runtime files are used.
EOF
}
fail() { printf 'AI Disk Auditor: %s\n' "$1" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] && [ -n "$3" ] || fail "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    -c|--comprehensive) COMPREHENSIVE=true; shift ;;
    -r|--report) LEGACY_REPORT=true; shift ;;
    --home-only) HOME_ONLY=true; shift ;;
    --root|--storage-root|--model-root|--strata-root|--report-path)
      need_value "$1" "$#" "${2:-}"
      case "$1" in
        --root) CUSTOM_ROOTS[${#CUSTOM_ROOTS[@]}]=$2 ;;
        --storage-root) STORAGE_ROOTS[${#STORAGE_ROOTS[@]}]=$2 ;;
        --model-root) MODEL_ROOT=$2 ;;
        --strata-root) STRATA_ROOT=$2 ;;
        --report-path) REPORT_PATH=$2 ;;
      esac
      shift 2 ;;
    --report-path=*) REPORT_PATH=${1#*=}; [ -n "$REPORT_PATH" ] || fail '--report-path requires a value'; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1 (use --help)" ;;
  esac
done
[ "$LEGACY_REPORT" = true ] && [ -n "$REPORT_PATH" ] && fail 'use either --report or --report-path'
for tool in du awk sort; do command -v "$tool" >/dev/null 2>&1 || fail "required utility not found: $tool"; done

add_root() {
  local i
  [ -n "$3" ] || return
  for ((i=0; i<${#PATHS[@]}; i++)); do
    if [ "${PATHS[$i]}" = "$3" ]; then
      [ "${4:-false}" = true ] && REQUIRED[$i]=true
      return
    fi
  done
  i=${#PATHS[@]}; PATHS[$i]=$3; GROUPS_LIST[$i]=$1; LABELS[$i]=$2; REQUIRED[$i]=${4:-false}
}
configured_root() {
  local value=${!3} required=false
  if [ -n "$value" ]; then required=true; else value=$4; fi
  add_root "$1" "$2" "$value" "$required"
}
is_ai_name() {
  case "$1" in
    *model*|*Model*|strata*|Strata*|llama*|Llama*|vllm*|vLLM*|sglang*|SGLang*|\
    *comfy*|*Comfy*|*unsloth*|*Unsloth*|hf-cache*|huggingface*|lmstudio*|\
    ollama*|llm*|LLM*|*-llm*|*rocm*|*ROCm*|stable-diffusion*) return 0 ;;
    *) return 1 ;;
  esac
}
discover_projects() {
  local parent=$1 p name count=0
  [ -d "$parent" ] || return
  for p in "$parent"/*; do
    [ -d "$p" ] || continue
    count=$((count+1)); [ "$count" -le 200 ] || break
    name=${p##*/}
    is_ai_name "$name" && add_workspace "$p"
  done
}
add_workspace() {
  local child
  add_root Projects 'AI project / builds / environments' "$1"
  # Resolve known redirected stores/environments, never arbitrary interior links.
  for child in models checkpoints .venv venv; do
    [ -L "$1/$child" ] && add_root Projects 'Redirected project model store / environment' "$1/$child"
  done
}
discover_storage() {
  # Storage parent -> volume/project -> named AI directories. No recursive find.
  local parent=$1 p child name found count=0 inner
  [ -d "$parent" ] || return
  for p in "$parent"/*; do
    [ -d "$p" ] || continue
    count=$((count+1)); [ "$count" -le 200 ] || break
    case "${p##*/}" in
      models|Models|hf-cache*|huggingface*|lmstudio*|ollama*)
        add_root Storage 'Shared model store' "$p"; continue ;;
      comfyui*|ComfyUI*|strata*|llama.cpp*|unsloth*|vllm*|sglang*|llm-lab*)
        add_workspace "$p"; continue ;;
    esac
    found=false; inner=0
    for child in "$p"/*; do
      [ -d "$child" ] || continue
      inner=$((inner+1)); [ "$inner" -le 200 ] || break
      name=${child##*/}
      if is_ai_name "$name"; then
        add_root Storage 'Shared model / AI workspace' "$child"; found=true
      fi
    done
    # A direct model store/project may have weights at its root.
    if [ "$found" = false ] && is_ai_name "${p##*/}"; then
      add_root Storage 'Shared model / AI workspace' "$p"
    fi
  done
}

CACHE=${XDG_CACHE_HOME:-$HOME/.cache}
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
HF=${HF_HOME:-$CACHE/huggingface}
add_root Models 'LM Studio models and downloaded runtimes' "$HOME/.lmstudio"
add_root Models 'LM Studio redirected model store' "$HOME/.lmstudio/models"
add_root Models 'Ollama user data' "$HOME/.ollama"
configured_root Models 'Ollama model store' OLLAMA_MODELS "$HOME/.ollama/models"
configured_root Caches 'Hugging Face models / datasets / assets' HF_HOME "$CACHE/huggingface"
configured_root Caches 'Hugging Face Hub (custom location)' HF_HUB_CACHE "${HUGGINGFACE_HUB_CACHE:-$HF/hub}"
configured_root Caches 'Hugging Face Xet chunks' HF_XET_CACHE "$HF/xet"
configured_root Caches 'Hugging Face assets' HF_ASSETS_CACHE "$HF/assets"
configured_root Caches 'Torch / checkpoints / extensions' TORCH_HOME "$CACHE/torch"
configured_root Caches 'pip downloads / wheels' PIP_CACHE_DIR "$CACHE/pip"
configured_root Caches 'uv downloads / environments' UV_CACHE_DIR "$CACHE/uv"
configured_root Caches 'Triton kernels' TRITON_CACHE_DIR "$HOME/.triton/cache"
configured_root Caches 'CUDA compiled kernels' CUDA_CACHE_PATH "$HOME/.nv/ComputeCache"
configured_root Caches 'HIP compiled kernels' HIP_CACHE_DIR "$CACHE/hip"
configured_root Caches 'ROCm cache' ROCM_CACHE_DIR "$CACHE/amd"
configured_root Caches 'HSA cache' HSA_CACHE_DIR ''
configured_root Caches 'MIOpen kernels' MIOPEN_CUSTOM_CACHE_DIR "$CACHE/miopen"
configured_root Caches 'MIOpen database' MIOPEN_USER_DB_PATH ''
configured_root Caches 'C/C++ compiler cache' CCACHE_DIR "$CACHE/ccache"
configured_root Caches 'Shared compiler cache' SCCACHE_DIR "$CACHE/sccache"
configured_root Caches 'npm package cache' npm_config_cache "$HOME/.npm"
for p in "$CACHE/comgr" "$CACHE/torch_extensions" "$CACHE/vllm" "$CACHE/sglang" \
  "$CACHE/flashinfer" "$CACHE/unsloth" "$CACHE/lm-studio" "$CACHE/mlx" "$CACHE/coreml" \
  "$CACHE/llama.cpp" "$CACHE/llamacpp" "$CACHE/npm" "$CACHE/yarn" "$CACHE/pnpm" \
  "$HOME/unsloth_compiled_cache"; do add_root Caches 'AI / compiler / package cache' "$p"; done
for p in "$DATA/uv" "$DATA/llama.cpp" "$DATA/unsloth" "$DATA/virtualenv" \
  "$HOME/.unsloth" "$HOME/.venvs" "$HOME/venvs" "$HOME/.conda" \
  "$HOME/miniconda3" "$HOME/anaconda3" "$HOME/miniforge3" "$HOME/mambaforge"; do
  add_root Environments 'Python / AI environments and runtimes' "$p"
done
for p in "$DATA/ollama" "$DATA/LM Studio" "$HOME/.continue"; do
  add_root Models 'Local AI application data' "$p"
done
for p in "$HOME/AI" "$HOME/ai" "$HOME/Models" "$HOME/models" "$HOME/llm" "$HOME/LLM"; do
  add_root Projects 'AI workspace / models / environments' "$p"
done
for p in "$HOME" "$HOME/src" "$HOME/projects" "$HOME/workspace" "$HOME/.local/opt" "$DATA"; do discover_projects "$p"; done
if [ "$HOME_ONLY" = false ]; then
  for p in /mnt /media /srv /data; do discover_storage "$p"; done
  for p in /models /data/models /var/lib/ollama /usr/share/ollama/.ollama/models /usr/local/share/ollama; do
    add_root Models 'System model store' "$p"
  done
fi
for p in "${STORAGE_ROOTS[@]}"; do
  if [ -d "$p" ]; then discover_storage "$p"; else ISSUES[${#ISSUES[@]}]="Missing/inaccessible storage parent: $p"; fi
done
for p in "${CUSTOM_ROOTS[@]}"; do add_root Custom 'User-supplied directory' "$p" true; done
[ -n "$MODEL_ROOT" ] && add_root Models 'Configured model store' "$MODEL_ROOT" true
[ -n "$STRATA_ROOT" ] && add_root Projects 'Configured Strata workspace' "$STRATA_ROOT" true
if [ "$OS_NAME" = Darwin ]; then
  for p in "$HOME/Library/Caches/mlx" "$HOME/Library/Caches/com.apple.CoreML" \
    "$HOME/Library/Application Support/MLX" "$HOME/Library/Application Support/CoreML" \
    "$HOME/Library/Application Support/llama.cpp" "$HOME/Library/Application Support/LM Studio"; do
    add_root Models 'macOS AI application / cache' "$p"
  done
fi
if [ "$COMPREHENSIVE" = true ]; then
  for p in "$HOME/.cargo" "$HOME/.rustup" "$HOME/.bun"; do add_root Toolchains 'Development toolchain' "$p"; done
  if [ "$HOME_ONLY" = false ]; then
    for p in /opt/rocm /opt/rocm/core-* /opt/rocm-* /usr/local/cuda /usr/local/cuda-* /opt/intel; do
      add_root SDKs 'GPU SDK / runtime installation' "$p"
    done
    for p in /var/lib/docker /var/lib/containerd "$DATA/containers" "$HOME/.docker"; do
      add_root Containers 'Container data (access may be restricted)' "$p"
    done
  fi
  if [ "$OS_NAME" = Darwin ]; then
    for p in "$HOME/Library/Caches/com.apple.Metal" "$HOME/Library/Developer/CoreSimulator/Caches" \
      "$HOME/Library/Developer/Xcode/DerivedData"; do add_root Toolchains 'Apple developer cache' "$p"; done
  fi
fi

canonical_dir() ( cd -P -- "$1" 2>/dev/null && printf '%s.' "$PWD"; )
prepare_roots() {
  local i j raw path seen parent
  local candidates=() groups=() labels=()
  for ((i=0; i<${#PATHS[@]}; i++)); do
    raw=${PATHS[$i]}
    if [ ! -d "$raw" ]; then
      [ "${REQUIRED[$i]}" = true ] && ISSUES[${#ISSUES[@]}]="Missing/inaccessible configured directory: $raw"
      continue
    fi
    path=$(canonical_dir "$raw")
    if [ -z "$path" ]; then ISSUES[${#ISSUES[@]}]="Cannot resolve directory: $raw"; continue; fi
    path=${path%.}; seen=false
    for ((j=0; j<${#candidates[@]}; j++)); do [ "${candidates[$j]}" = "$path" ] && seen=true; done
    if [ "$raw" != "$path" ]; then
      printf -v raw '%q -> %q' "$raw" "$path"
      ALIASES[${#ALIASES[@]}]=$raw
    fi
    [ "$seen" = true ] && continue
    j=${#candidates[@]}; candidates[$j]=$path; groups[$j]=${GROUPS_LIST[$i]}; labels[$j]=${LABELS[$i]}
  done
  for ((i=0; i<${#candidates[@]}; i++)); do
    path=${candidates[$i]}; seen=false
    for ((j=0; j<${#candidates[@]}; j++)); do
      [ "$i" -eq "$j" ] && continue
      parent=${candidates[$j]%/}
      case "$path" in "$parent"/*)
        # Keep a separately mounted child: du -x on its parent excludes it.
        if command -v df >/dev/null 2>&1; then
          local child_fs parent_fs
          child_fs=$(df -P "$path" 2>/dev/null | awk 'END {print $1}')
          parent_fs=$(df -P "${candidates[$j]}" 2>/dev/null | awk 'END {print $1}')
          [ -n "$child_fs" ] && [ "$child_fs" = "$parent_fs" ] && seen=true
        fi ;;
      esac
    done
    if [ "$seen" = true ]; then COVERED=$((COVERED+1)); continue; fi
    j=${#SELECTED_PATHS[@]}; SELECTED_PATHS[$j]=$path; SELECTED_GROUPS[$j]=${groups[$i]}; SELECTED_LABELS[$j]=${labels[$i]}
  done
}
runtime_context() {
  local tool path any=false
  printf '\nDetected tools (presence only; no service queries):\n'
  for tool in ollama lms llama-server python3 uv conda docker podman nvcc hipcc; do
    path=$(command -v "$tool" 2>/dev/null)
    if [ -n "$path" ]; then printf '  %-14s %q\n' "$tool" "$path"; any=true; fi
  done
  [ "$any" = true ] || printf '  None found on PATH.\n'
  if [ "$HOME_ONLY" = false ]; then
    printf '\nGPU SDK locations (measure with --comprehensive):\n'; any=false
    for path in /opt/rocm/core-* /opt/rocm-* /usr/local/cuda /usr/local/cuda-*; do
      [ -d "$path" ] || continue
      printf '  %q\n' "$path"; any=true
    done
    [ "$any" = true ] || printf '  No conventional ROCm/CUDA installation found.\n'
  fi
}
scan() {
  local i raw kb rc status escaped group label number
  local rows=() errors=0
  printf 'AI Disk Auditor - Linux/macOS\n'
  printf 'Read-only audit of model stores, caches, AI workspaces and environments.\n'
  if [ "$COMPREHENSIVE" = true ]; then printf 'Mode: comprehensive (includes SDK/toolchain/container folders)\n'; else printf 'Mode: quick (use --comprehensive for SDK/toolchain/container sizes)\n'; fi
  prepare_roots
  printf '\nMeasuring %s distinct directories; %s nested locations included in their parents.\n' "${#SELECTED_PATHS[@]}" "$COVERED"
  for ((i=0; i<${#SELECTED_PATHS[@]}; i++)); do
    raw=$(du -skx "${SELECTED_PATHS[$i]}" 2>/dev/null); rc=$?
    kb=$(printf '%s\n' "$raw" | awk 'NR==1 && $1 ~ /^[0-9]+$/ {print $1}')
    status=OK
    if [ "$rc" -ne 0 ]; then status=PARTIAL; errors=$((errors+1)); fi
    if [ -z "$kb" ]; then kb=-1; status=UNREADABLE; [ "$rc" -eq 0 ] && errors=$((errors+1)); fi
    printf -v escaped '%q' "${SELECTED_PATHS[$i]}"
    rows[${#rows[@]}]="$kb"$'\t'"${SELECTED_GROUPS[$i]}"$'\t'"$status"$'\t'"${SELECTED_LABELS[$i]}"$'\t'"$escaped"
  done
  printf '\nSIZE (GiB)  STATUS      CATEGORY       DIRECTORY\n'
  if [ "${#rows[@]}" -gt 0 ]; then
    printf '%s\n' "${rows[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr | while IFS=$'\t' read -r kb group status label escaped; do
      if [ "$kb" -lt 0 ]; then number='?'; else
        number=$(awk -v k="$kb" 'BEGIN {if(k==0)print "0"; else if(k<10485.76)print "<0.01"; else printf "%.2f",k/1048576}')
      fi
      printf '%10s  %-10s  %-13s  %s\n' "$number" "$status" "$group" "$escaped"
      printf '                                      %s\n' "$label"
    done
  else printf 'No matching readable AI directories found. Use --root DIR for another location.\n'; fi
  printf '\nSizes are allocated disk usage, largest first. Nested directories are not listed twice.\n'
  printf 'Hard links across separate rows may share storage; rows are not additive or reclaimable totals.\n'
  printf 'PARTIAL means readable bytes only; ? means sizing failed, not an empty directory.\n'
  if [ "${#ALIASES[@]}" -gt 0 ]; then
    printf '\nResolved directory links:\n'
    printf '  %s\n' "${ALIASES[@]}" | LC_ALL=C sort -u
  fi
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    printf '\nConfiguration/access issues:\n'
    for raw in "${ISSUES[@]}"; do printf '  ERROR %q\n' "$raw"; done
  fi
  [ "$errors" -gt 0 ] && printf '\nScan errors: %s directories could not be completely sized.\n' "$errors"
  runtime_context
  printf '\nFilesystem capacity for the scanned locations:\n'
  if command -v df >/dev/null 2>&1; then
    df -hP "$HOME" "${SELECTED_PATHS[@]}" 2>&1 | awk '!seen[$0]++'
    printf '\nFilesystem inode usage:\n'
    df -iP "$HOME" "${SELECTED_PATHS[@]}" 2>&1 | awk '!seen[$0]++'
  else printf 'df unavailable\n'; fi
  printf '\nDiscovery is limited to known locations and named AI folders. Use --root DIR for unlisted stores.\n'
}

if [ "$LEGACY_REPORT" = true ]; then
  REPORT_DIR="$HOME/AI-Disk-Audit-Reports"
  mkdir -p "$REPORT_DIR" 2>/dev/null || fail "cannot create report directory: $REPORT_DIR"
  REPORT_PATH="$REPORT_DIR/ai-disk-audit_$(date +%Y-%m-%d_%H-%M-%S).txt"
fi
if [ -n "$REPORT_PATH" ]; then
  [ -e "$REPORT_PATH" ] || [ -L "$REPORT_PATH" ] && fail "report destination already exists: $REPORT_PATH"
  (set -C; scan > "$REPORT_PATH") || fail "cannot create report: $REPORT_PATH"
  cat "$REPORT_PATH"
  printf '\nReport saved to: %q\n' "$REPORT_PATH"
else scan; fi
