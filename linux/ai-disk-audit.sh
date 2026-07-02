#!/usr/bin/env bash

# AI Disk Auditor v1.0 - Linux/macOS
#
# Read-only scanner for local AI/model/cache folders.
#
# Safety:
# - Does not delete files
# - Does not move files
# - Does not change shell profiles
# - Does not stop services
# - Does not unload models
# - Skips inaccessible folders safely

set +e

COMPREHENSIVE=false
REPORT=false
START_TIME=$(date +%s)

for arg in "$@"; do
  case "$arg" in
    --comprehensive|-c) COMPREHENSIVE=true ;;
    --report|-r) REPORT=true ;;
    --help|-h)
      echo "Usage:"
      echo "  ./ai-disk-audit.sh"
      echo "  ./ai-disk-audit.sh --report"
      echo "  ./ai-disk-audit.sh --comprehensive"
      echo "  ./ai-disk-audit.sh --comprehensive --report"
      exit 0 ;;
    *) echo "Unknown option: $arg"; echo "Use --help for usage."; exit 1 ;;
  esac
done

print_header() {
  echo ""
  echo "AI Disk Auditor v1.0 - Linux/macOS"
  echo "Read-only audit. This script does not delete, move, or modify files."
  echo "If a folder cannot be scanned, it will be skipped safely."
  echo "Press Ctrl+C at any time to cancel safely."
  echo ""
  if [ "$COMPREHENSIVE" = true ]; then
    echo "Mode: Comprehensive scan. This may take a while."
  else
    echo "Mode: Quick scan. Use --comprehensive for deeper scanning."
  fi
  JOKES=(
    "Scanning for AI leftovers. Some may be deprecated. Some may be Microsoft."
    "Local AI archaeology mode: caches, models, and forgotten SDKs."
    "If this takes too long, at least it is not WindowsApps."
    "Comprehensive scan enabled: consulting dotfolders and other mythical realms."
    "Warning: this script may discover three SDKs, two runtimes, and one deprecated dream."
  )
  RANDOM_INDEX=$((RANDOM % ${#JOKES[@]}))
  echo ""
  echo "${JOKES[$RANDOM_INDEX]}"
  echo ""
}

print_section() { echo ""; echo "=== $1 ==="; }

size_gb() {
  local path="$1"
  if [ ! -e "$path" ]; then return; fi
  local size_kb
  size_kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
  if [ -z "$size_kb" ]; then echo "0.00"; else awk "BEGIN { printf \"%.2f\", $size_kb / 1024 / 1024 }"; fi
}

run_audit() {
  print_header
  QUICK_TARGETS=(
    "$HOME/.ollama" "$HOME/.lmstudio" "$HOME/.continue" "$HOME/.cache/huggingface"
    "$HOME/.cache/torch" "$HOME/.cache/pip" "$HOME/.cache/uv" "$HOME/.cache/npm"
    "$HOME/.cache/yarn" "$HOME/.cache/pnpm" "$HOME/.cache/mlx" "$HOME/.cache/llama.cpp"
    "$HOME/.cache/llamacpp" "$HOME/.cache/coreml" "$HOME/.cargo" "$HOME/.rustup"
    "$HOME/.conda" "$HOME/.docker" "$HOME/AI" "$HOME/Models" "$HOME/models"
    "$HOME/llm" "$HOME/LLM" "$HOME/stable-diffusion-webui" "$HOME/ComfyUI"
    "$HOME/Library/Caches/mlx" "$HOME/Library/Caches/com.apple.CoreML"
    "$HOME/Library/Application Support/MLX" "$HOME/Library/Application Support/CoreML"
    "$HOME/Library/Application Support/llama.cpp"
  )
  COMPREHENSIVE_TARGETS=(
    "${QUICK_TARGETS[@]}" "$HOME/.cache" "$HOME/.local/share" "$HOME/.local/share/ollama"
    "$HOME/.local/share/LM Studio" "$HOME/Library/Application Support/LM Studio"
    "$HOME/Library/Caches" "$HOME/Library/Caches/huggingface" "$HOME/Library/Caches/com.apple.Metal"
    "$HOME/Library/Application Support" "$HOME/Library/Developer/CoreSimulator/Caches"
    "$HOME/Library/Developer/Xcode/DerivedData" "/opt/rocm" "/opt/intel" "/opt/intel/openvino"
    "/usr/local/cuda" "/usr/local/share" "/var/lib/ollama" "/var/lib/docker" "/tmp"
  )
  if [ "$COMPREHENSIVE" = true ]; then TARGETS=("${COMPREHENSIVE_TARGETS[@]}"); else TARGETS=("${QUICK_TARGETS[@]}"); fi

  print_section "Folder Size Summary"
  TMP_REPORT=$(mktemp 2>/dev/null || echo "/tmp/ai-disk-audit-temp.txt")
  : > "$TMP_REPORT"
  for target in "${TARGETS[@]}"; do
    if [ -e "$target" ]; then
      size=$(size_gb "$target")
      if [ -n "$size" ]; then printf "%10s GB    %s\n" "$size" "$target" >> "$TMP_REPORT"; fi
    fi
  done
  sort -nr "$TMP_REPORT"
  rm -f "$TMP_REPORT"

  print_section "Ollama Models"
  if command -v ollama >/dev/null 2>&1; then ollama list; else echo "Ollama not found or not available."; fi

  print_section "LM Studio"
  if [ -d "$HOME/.lmstudio" ]; then
    echo "LM Studio folder found: $HOME/.lmstudio"
  elif [ -d "$HOME/Library/Application Support/LM Studio" ]; then
    echo "LM Studio folder found: $HOME/Library/Application Support/LM Studio"
  else
    echo "LM Studio folder not found in common locations."
  fi
  END_TIME=$(date +%s)
  ELAPSED=$((END_TIME - START_TIME))
  echo ""
  echo "Completed in ${ELAPSED} seconds."
}

if [ "$REPORT" = true ]; then
  REPORT_DIR="$HOME/AI-Disk-Audit-Reports"
  mkdir -p "$REPORT_DIR"
  TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
  REPORT_PATH="$REPORT_DIR/ai-disk-audit_$TIMESTAMP.txt"
  run_audit | tee "$REPORT_PATH"
  echo ""
  echo "Report saved to: $REPORT_PATH"
else
  run_audit
fi
