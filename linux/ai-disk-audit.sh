#!/usr/bin/env bash
# AI Disk Auditor: standalone, read-only Linux/macOS storage inventory.
# Bash 3.2 compatible. Only explicit report options create files.
set +e

COMPREHENSIVE=false
HOME_ONLY=false
LIST_ROOTS=false
DIAGNOSTICS=false
NO_INVENTORY=false
MODEL_LIMIT=500
GATEWAY_ROOT=${AI_AUDIT_GATEWAY_ROOT:-}
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
DEVICE_PROBES=0
MEASUREMENTS=0

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
      --list-roots       Show selected roots without measuring file trees
      --no-inventory     Only measure directories; skip file identification
      --model-limit N    Maximum model rows and header inspections (default 500)
      --gateway-root DIR Include gateway code (or AI_AUDIT_GATEWAY_ROOT)
      --diagnostics      Show traversal counts and planning statistics
  -h, --help             Show this help

Quick mode includes known model/cache locations, named AI projects, Python
environments and AI directories on shared storage. Discovery examines directory
names at bounded depth. Optional installed Python enriches bounded model headers
and manifests; tensors, secrets and gateway settings are never loaded.
No cleanup, sudo, daemon calls, installation or adjacent runtime files are used.
EOF
}
fail() { printf 'AI Disk Auditor: %s\n' "$1" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] && [ -n "$3" ] || fail "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    -c|--comprehensive) COMPREHENSIVE=true; shift ;;
    -r|--report) LEGACY_REPORT=true; shift ;;
    --no-inventory) NO_INVENTORY=true; shift ;;
    --home-only) HOME_ONLY=true; shift ;;
    --list-roots) LIST_ROOTS=true; shift ;;
    --diagnostics) DIAGNOSTICS=true; shift ;;
    --root|--storage-root|--model-root|--strata-root|--report-path|--model-limit|--gateway-root)
      need_value "$1" "$#" "${2:-}"
      case "$1" in
        --model-limit) MODEL_LIMIT=$2 ;;
        --gateway-root) GATEWAY_ROOT=$2 ;;
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
case "$MODEL_LIMIT" in ''|*[!0-9]*) fail '--model-limit must be 1..10000' ;; esac
[ "${#MODEL_LIMIT}" -le 5 ] && [ "$MODEL_LIMIT" -ge 1 ] && [ "$MODEL_LIMIT" -le 10000 ] || fail '--model-limit must be 1..10000'
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
    AI|ai|*model*|*Model*|strata*|Strata*|llama*|Llama*|vllm*|vLLM*|sglang*|SGLang*|\
    *comfy*|*Comfy*|*unsloth*|*Unsloth*|hf-cache*|huggingface*|lmstudio*|\
    ollama*|llm*|LLM*|*-llm*|*rocm*|*ROCm*|stable-diffusion*) return 0 ;;
    *) return 1 ;;
  esac
}
discover_projects() {
  local parent=$1 p name count=0
  [ -d "$parent" ] || return
  for p in "$parent"/*; do
    name=${p##*/}
    is_ai_name "$name" || continue
    [ -d "$p" ] || continue
    count=$((count+1))
    if [ "$count" -gt 200 ]; then ISSUES[${#ISSUES[@]}]="Discovery limit reached (200 matching projects): $parent; use --root for more"; break; fi
    add_workspace "$p"
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
  local parent=$1 depth=${2:-1} p child name found count=0 inner
  [ -d "$parent" ] || return
  for p in "$parent"/*; do
    [ -d "$p" ] || continue
    count=$((count+1))
    if [ "$count" -gt 200 ]; then ISSUES[${#ISSUES[@]}]="Discovery limit reached (200 storage containers): $parent; use --storage-root for more"; break; fi
    case "${p##*/}" in
      models|Models|hf-cache*|huggingface*|lmstudio*|ollama*)
        add_root Storage 'Shared model store' "$p"; continue ;;
      comfyui*|ComfyUI*|strata*|llama.cpp*|unsloth*|vllm*|sglang*)
        add_workspace "$p"; continue ;;
    esac
    found=false; inner=0
    for child in "$p"/*; do
      name=${child##*/}
      if is_ai_name "$name" && [ -d "$child" ]; then
        inner=$((inner+1))
        if [ "$inner" -gt 200 ]; then ISSUES[${#ISSUES[@]}]="Discovery limit reached (200 matching stores): $p; use --root for more"; break; fi
        add_root Storage 'Shared model / AI workspace' "$child"; found=true
      fi
    done
    # A direct model store/project may have weights at its root.
    if [ "$found" = false ] && is_ai_name "${p##*/}"; then
      add_root Storage 'Shared model / AI workspace' "$p"
    elif [ "$found" = false ] && [ "$depth" -gt 1 ]; then
      discover_storage "$p" "$((depth-1))"
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
configured_root Caches 'Hugging Face datasets' HF_DATASETS_CACHE "$HF/datasets"
configured_root Caches 'Torch / checkpoints / extensions' TORCH_HOME "$CACHE/torch"
configured_root Caches 'pip downloads / wheels' PIP_CACHE_DIR "$CACHE/pip"
configured_root Caches 'uv downloads / environments' UV_CACHE_DIR "$CACHE/uv"
configured_root Caches 'vLLM cache' VLLM_CACHE_ROOT "$CACHE/vllm"
configured_root Environments 'uv Python installations' UV_PYTHON_INSTALL_DIR "$DATA/uv/python"
configured_root Environments 'uv tools' UV_TOOL_DIR "$DATA/uv/tools"
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
  for p in /mnt /srv /data; do discover_storage "$p"; done
  discover_storage /media 2
  [ "$OS_NAME" = Darwin ] && discover_storage /Volumes
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
filesystem_id() {
  local value
  if command -v stat >/dev/null 2>&1; then
    if [ "$OS_NAME" = Darwin ]; then value=$(stat -f %d "$1" 2>/dev/null)
    else value=$(stat -c %d -- "$1" 2>/dev/null); fi
    if [ -n "$value" ]; then printf 'stat:%s' "$value"; return; fi
  fi
  value=$(df -P "$1" 2>/dev/null | awk 'END {if(NR>1)print $1}')
  [ -n "$value" ] && printf 'df:%s' "$value"
}
prepare_roots() {
  add_root Gateways 'Gateway code' "$GATEWAY_ROOT" true
  for gateway in "$HOME/.hermes" "$HOME/litellm" "$HOME/open-webui" "$HOME/local-ai"; do
    [ -d "$gateway" ] && add_root Gateways 'Gateway/frontend candidate' "$gateway"
  done
  local i j raw path seen parent
  local candidates=() groups=() labels=() devices=()
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
    devices[$j]='__pending__'
  done
  for ((i=0; i<${#candidates[@]}; i++)); do
    path=${candidates[$i]}; seen=false
    for ((j=0; j<${#candidates[@]}; j++)); do
      [ "$i" -eq "$j" ] && continue
      parent=${candidates[$j]%/}
      case "$path" in "$parent"/*)
        # Keep a separately mounted child: du -x on its parent excludes it.
        # Probe only overlapping candidates, caching each identity once.
        if [ "${devices[$i]}" = '__pending__' ]; then
          devices[$i]=$(filesystem_id "$path"); DEVICE_PROBES=$((DEVICE_PROBES+1))
        fi
        if [ "${devices[$j]}" = '__pending__' ]; then
          devices[$j]=$(filesystem_id "${candidates[$j]}"); DEVICE_PROBES=$((DEVICE_PROBES+1))
        fi
        [ -n "${devices[$i]}" ] && [ "${devices[$i]}" = "${devices[$j]}" ] && seen=true ;;
      esac
    done
    if [ "$seen" = true ]; then COVERED=$((COVERED+1)); continue; fi
    j=${#SELECTED_PATHS[@]}; SELECTED_PATHS[$j]=$path; SELECTED_GROUPS[$j]=${groups[$i]}; SELECTED_LABELS[$j]=${labels[$i]}
  done
}
inventory() {
  [ "$NO_INVENTORY" = true ] && return
  local i group path name role count=0
  local args=()
  local shard_patterns=() shard_counts=() shard_expected=() shard_indices=()
  local pattern index expected slot j missing present
  for ((i=0; i<${#SELECTED_PATHS[@]}; i++)); do
    group=${SELECTED_GROUPS[$i]}
    if [ "$group" = Caches ]; then
      case "${SELECTED_LABELS[$i]}" in *Hugging*|*hugging*|*HF*|*Torch*|*torch*|*vLLM*|*vllm*) group=ModelCache ;; *) continue ;; esac
    fi
    case "$group" in Toolchains|Containers) continue ;; esac
    args[${#args[@]}]=$group; args[${#args[@]}]=${SELECTED_PATHS[$i]}
  done
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$MODEL_LIMIT" "$HOME_ONLY" "${args[@]}" <<'AI_AUDIT_METADATA_PY'
"""Embedded, optional Linux metadata enrichment. No dependencies or tensor reads."""
import collections, glob, json, os, re, struct, sys
from pathlib import Path

LIMIT=int(sys.argv[1]); HOME_ONLY=sys.argv[2]=='true'
ROOTS=list(zip(sys.argv[3::2],sys.argv[4::2]))
MAX_HEADER=8*1024*1024
MAX_METADATA=256*1024*1024
FT={0:'F32',1:'F16',2:'Q4_0',3:'Q4_1',7:'Q8_0',8:'Q5_0',9:'Q5_1',10:'Q2_K',11:'Q3_K_S',12:'Q3_K_M',13:'Q3_K_L',14:'Q4_K_S',15:'Q4_K_M',16:'Q5_K_S',17:'Q5_K_M',18:'Q6_K',19:'IQ2_XXS',20:'IQ2_XS',21:'Q2_K_S',22:'IQ3_XS',23:'IQ3_XXS',24:'IQ1_S',25:'IQ4_NL',26:'IQ3_S',27:'IQ3_M',28:'IQ2_S',29:'IQ2_M',30:'IQ4_XS',31:'IQ1_M',32:'BF16',36:'TQ1_0',37:'TQ2_0',38:'MXFP4_MOE',39:'NVFP4',40:'Q1_0',41:'Q2_0'}
QUANT=re.compile(r'(?i)(?:UD-)?(?:IQ[1-4]_[A-Z0-9_]+|Q[1-8](?:_[A-Z0-9]+)+|TQ[12]_0|BF16|F16|FP16|F32|FP32|FP8|MXFP4(?:_MOE)?|NVFP4)')
SECRET={'.ssh','.gnupg','credentials','secrets','.env'}
PRUNE=SECRET|{'.git','node_modules','__pycache__','.venv','venv','site-packages','sessions','logs','conversations','tests','test','examples'}
records={}; issues=[]; configs={}; counts=collections.Counter(); manifest_roots=set(); shard_headers={}

def clean(value):
    return re.sub(r'[\x00-\x1f\x7f]', '?', str(value))[:240]
def safe(path):
    return not any(p.lower() in SECRET or p.lower().endswith(('.pem','.key')) for p in Path(path).parts)
def small_json(path,limit=1024*1024):
    path=Path(path)
    if not safe(path.resolve()) or path.stat().st_size>limit: return {}
    with path.open('rb') as f: value=json.load(f)
    return value if isinstance(value,dict) else {}
def gguf(path):
    meta={}; steps=[0]
    with open(path,'rb') as f:
        if f.read(4) not in (b'GGUF',b'FUGG'): return {},''
        version=f.read(4); endian='<' if int.from_bytes(version,'little') in (2,3) else '>'
        if int.from_bytes(version,'little' if endian=='<' else 'big') not in (2,3): return {},'unsupported GGUF version'
        def number(fmt):
            n=struct.calcsize(fmt); data=f.read(n)
            if len(data)!=n: raise ValueError('truncated metadata')
            return struct.unpack(endian+fmt,data)[0]
        def skip(n):
            if n<0 or f.tell()+n>min(os.fstat(f.fileno()).st_size,MAX_METADATA): raise ValueError('metadata limit/truncation')
            f.seek(n,1)
        def string(keep):
            n=number('Q')
            if n>MAX_METADATA or f.tell()+n>MAX_METADATA: raise ValueError('metadata string limit')
            if keep:
                if n>4096: skip(n); return '(metadata string omitted: too long)'
                data=f.read(n)
                if len(data)!=n: raise ValueError('truncated string')
                return data.decode('utf-8','replace')
            skip(n)
        def value(kind,keep=False,depth=0):
            steps[0]+=1
            if steps[0]>2000000 or depth>2: raise ValueError('metadata item limit')
            formats={0:'B',1:'b',2:'H',3:'h',4:'I',5:'i',6:'f',7:'?',10:'Q',11:'q',12:'d'}
            if kind in formats:
                if keep:return number(formats[kind])
                skip(struct.calcsize(formats[kind])); return None
            if kind==8:return string(keep)
            if kind==9:
                sub=number('I'); count=number('Q')
                if count>2000000: raise ValueError('metadata array limit')
                if sub in formats:skip(count*struct.calcsize(formats[sub]))
                else:
                    for _ in range(count):value(sub,False,depth+1)
                return None
            raise ValueError('unknown metadata type')
        try:
            number('Q'); total=number('Q')
            if total>100000:raise ValueError('metadata key limit')
            for _ in range(total):
                key=string(True); kind=number('I')
                keep=key.endswith('.nextn_predict_layers') or key in {'general.name','general.author','general.organization','general.architecture','general.type','general.file_type','general.quantized_by','clip.projector_type'}
                data=value(kind,keep)
                if keep and data is not None:meta[key]=data
            return meta,''
        except (ValueError,OSError,struct.error) as e:return meta,str(e)

def classify(path):
    name=path.name.lower(); lower=str(path).replace('\\','/').lower(); ext=path.suffix.lower()
    role=''; fmt=''; source='filename'; model=True
    if ('ngram' in name or 'n-gram' in name) and ext in {'.bin','.gguf','.table'}:role='n-gram table candidate';fmt=ext.lstrip('.').upper() or 'unknown'
    elif ('mmproj' in name or 'projector' in name) and ext in {'.gguf','.bin','.safetensors'}:role='multimodal projector candidate';fmt=ext.lstrip('.').upper()
    elif re.search(r'(^|[-_.])mtp([-_.]|$)',name) and ext in {'.gguf','.bin','.safetensors'}:role='MTP sidecar candidate';fmt=ext.lstrip('.').upper()
    elif ext in {'.gguf','.safetensors','.onnx','.pt','.pth','.ckpt','.tflite','.npz','.mlmodel'}:role='model/weights';fmt=ext.lstrip('.').upper()
    elif name.startswith(('pytorch_model','adapter_model')) and ext=='.bin':role='adapter weights' if 'adapter' in name else 'model weights';fmt='BIN'
    elif '/blobs/' in lower and re.fullmatch(r'(?:sha256-)?[a-f0-9]{40,64}',name):role='cached model blob candidate';fmt='unknown'
    elif re.search(r'(ggml|cuda|cudnn|cublas|amdhip|hipblas|hiprtc|rocblas|vulkan|directml|mlx|metal)',name) and (re.search(r'\.(so(?:\..*)?|dll|dylib|metallib|metal)$',name)):
        backend='ROCm/HIP' if re.search('hip|rocblas|rocm',name) else 'CUDA' if re.search('cuda|cudnn|cublas',name) else 'Vulkan' if 'vulkan' in name else 'Metal/MLX' if re.search('metal|mlx',name) else 'DirectML' if 'directml' in name else 'GGML/CPU'
        return {'role':backend+' backend library','format':ext.lstrip('.').upper(),'source':'filename/path','model':False,'category':'Backends'}
    elif (re.search(r'gateway|proxy|litellm|frontdoor|openai[-_]server',name) and ext in {'.py','.js','.sh','.ps1','.exe',''}) and not any(p in lower for p in ['/site-packages/','/node_modules/']):
        return {'role':'gateway/API frontend candidate','format':ext.lstrip('.').upper() or 'executable/script','source':'filename/path','model':False,'category':'Gateways'}
    elif name in {'llama-server','llama-server.exe','ollama','ollama.exe','local-ai','local-ai.exe'}:
        return {'role':'inference server executable','format':'executable','source':'filename/path','model':False,'category':'Backends'}
    if not role:return None
    return {'role':role,'format':fmt,'source':source,'model':model,'category':'Models'}

def add(path,reference=''):
    try:
        p=Path(path); actual=p.resolve()
        if not safe(actual) or not p.is_file():return
        key=str(actual)
        if key in records:
            if reference:records[key]['refs'].add(reference)
            if Path(records[key]['path']).suffix=='' and p.suffix:
                records[key]['path']=str(p)
            return
        info=classify(p)
        if not info:return
        info.update(path=str(p),actual=key,size=p.stat().st_size,refs={reference} if reference else set())
        records[key]=info
    except OSError as e:issues.append('Cannot inventory '+str(path)+': '+type(e).__name__)

def manifests(base):
    if str(base) in manifest_roots:return
    manifest_roots.add(str(base))
    folder=base/'manifests'; blobs=base/'blobs'
    if not folder.is_dir() or not blobs.is_dir():return
    found=0
    for parent,dirs,files in os.walk(folder,followlinks=False):
        dirs[:]=[d for d in dirs if d not in PRUNE and not (Path(parent)/d).is_symlink()]
        for name in files:
            found+=1
            if found>1000:issues.append('Ollama manifest limit reached: '+str(folder));return
            path=Path(parent)/name
            try:
                data=small_json(path)
                for layer in data.get('layers',[]):
                    media=str(layer.get('mediaType',''))
                    if not any(x in media for x in ['image.model','image.projector','image.adapter','image.tensor']):continue
                    digest=str(layer.get('digest',''))
                    if not re.fullmatch(r'sha256:[a-f0-9]{64}',digest):continue
                    target=blobs/digest.replace(':','-')
                    rel=str(path.relative_to(folder)).replace('\\','/')
                    add(target,'Ollama manifest: '+rel)
                    item=records.get(str(target.resolve()))
                    if item and 'projector' in media:item['role']='multimodal projector (manifest)';item['source']='Ollama manifest'
                    if item and 'adapter' in media:item['role']='adapter weights (manifest)';item['source']='Ollama manifest'
            except (OSError,ValueError,TypeError):issues.append('Unreadable/invalid Ollama manifest: '+str(path))

visited=set(); entries=0
for group,raw in ROOTS:
    if entries>300000:break
    root=Path(raw)
    # Package/compile caches are measured by the size scan, not walked again.
    if group in {'Toolchains','Containers'}:continue
    if group=='Environments':
        for pattern in ['lib/python*/site-packages/torch/lib/*','lib/python*/site-packages/nvidia/*/lib/*','lib/python*/site-packages/onnxruntime/capi/*','lib/python*/site-packages/llama_cpp/lib/*','lib/python*/site-packages/mlx/lib/*']:
            for path in glob.glob(str(root/pattern)):add(path)
        continue
    if group=='Caches':continue
    for base in (root,root/'models'):manifests(base)
    for parent,dirs,files in os.walk(root,followlinks=False):
        try:
            st=os.stat(parent);key=(st.st_dev,st.st_ino)
            if key in visited:dirs[:]=[];continue
            if st.st_dev!=root.stat().st_dev:dirs[:]=[];continue
            visited.add(key)
        except OSError:dirs[:]=[];continue
        dirs[:]=[d for d in dirs if d.lower() not in PRUNE and not (Path(parent)/d).is_symlink()]
        if (Path(parent)/'manifests').is_dir() and (Path(parent)/'blobs').is_dir():manifests(Path(parent))
        for name in files:
            entries+=1
            if entries>300000:issues.append('Inventory entry budget reached; use a narrower --root');break
            path=Path(parent)/name
            if classify(path):add(path)
        if entries>300000:break

if not HOME_ONLY:
    for pattern in ['/opt/rocm/lib/libamdhip64.so*','/opt/rocm/core-*/lib/libamdhip64.so*','/usr/local/cuda*/lib64/libcudart.so*','/usr/lib/*/libvulkan.so*','/usr/lib/libvulkan.so*']:
        for path in glob.glob(pattern):add(path)
    if Path('/System/Library/Frameworks/Metal.framework').is_dir():
        records['Metal.framework']={'category':'Backends','model':False,'role':'Metal GPU framework','format':'framework','source':'installed path','path':'/System/Library/Frameworks/Metal.framework','size':0,'refs':set()}

def enrich(item):
    path=Path(item['path']);meta={};note='';quant='unknown';publisher='unknown';repo='unknown';dtype=''
    hint=QUANT.search(path.name)
    item['hint']=hint.group(0) if hint else ''
    try:
        with path.open('rb') as f:magic=f.read(4)
        if magic in (b'GGUF',b'FUGG'):
            item['format']='GGUF';meta,note=gguf(path)
            first=path.with_name(re.sub(r'-\d{5}-of-(\d{5})\.gguf$',r'-00001-of-\1.gguf',path.name))
            if first!=path and first.is_file() and safe(first.resolve()) and 'general.file_type' not in meta:
                if str(first) not in shard_headers:shard_headers[str(first)]=gguf(first)[0]
                for key,value in shard_headers[str(first)].items():meta.setdefault(key,value)
                note=(note+'; ' if note else '')+'missing identity fields inherited from first-shard GGUF header; tensors not validated'
            item['name']=clean(meta.get('general.name',path.name))
            publisher=clean(meta.get('general.organization') or meta.get('general.author') or 'unknown')
            if publisher!='unknown':publisher+=' [GGUF declared]'
            if 'general.file_type' in meta:quant=FT.get(meta['general.file_type'],'file_type='+str(meta['general.file_type']))+' [GGUF]'
            if meta.get('general.type')=='mmproj' or meta.get('general.architecture') in {'clip','mmproj'} or 'clip.projector_type' in meta:
                item['role']='multimodal projector/encoder [GGUF]'
            elif str(meta.get('general.type','')).lower()=='mtp':item['role']='MTP sidecar [GGUF]'
            elif item['role']=='cached model blob candidate':item['role']='model weights [GGUF]'
            if meta.get('general.quantized_by'):item['quantizer']=clean(meta['general.quantized_by'])+' [GGUF declared]'
        elif item['format']=='GGUF':note='GGUF extension but invalid/missing GGUF magic'
        elif item['format']=='SAFETENSORS' or item['role']=='cached model blob candidate':
            with path.open('rb') as f:
                n=struct.unpack('<Q',f.read(8))[0]
                if n>MAX_HEADER or n<2 or n+8>path.stat().st_size:raise ValueError('safetensors header limit/unknown blob format')
                header=json.loads(f.read(n))
            if not isinstance(header,dict):raise ValueError('invalid safetensors header object')
            dtype=','.join(sorted({str(v.get('dtype')) for k,v in header.items() if k!='__metadata__' and isinstance(v,dict) and 'dtype' in v and isinstance(v.get('shape'),list) and isinstance(v.get('data_offsets'),list) and len(v['data_offsets'])==2}))
            if not dtype:raise ValueError('no tensor descriptors')
            item['format']='SAFETENSORS';item['role']='model/tensor weights [header]' if item['role']=='cached model blob candidate' else item['role']
        match=re.search(r'(?:^|[/\\])models--([^/\\]+)',str(path))
        if match:repo=match.group(1).replace('--','/',1)+' [cache path; uploader, not verified publisher]'
        elif '.lmstudio' in path.parts:
            parts=list(path.parts)
            if 'models' in parts:
                i=parts.index('models')
                if len(parts)>i+3:repo=parts[i+1]+'/'+parts[i+2]+' [LM Studio path]'
        config=path.parent/'config.json'
        if config.is_file():
            key=str(config)
            if key not in configs:configs[key]=small_json(config)
            q=configs[key].get('quantization_config',{})
            if isinstance(q,dict) and q.get('quant_method') and quant=='unknown':
                quant=clean(q['quant_method'])+(' '+str(q['bits'])+'-bit' if 'bits' in q else '')+' [config]'
    except (OSError,ValueError,struct.error,TypeError) as e:note=str(e)[:140]
    item.update(quant=quant,publisher=publisher,repo=repo,dtype=dtype,note=note,arch=clean(meta.get('general.architecture',configs.get(str(path.parent/'config.json'),{}).get('model_type','unknown'))),mtp={k:v for k,v in meta.items() if k.endswith('.nextn_predict_layers')})

print('\n=== Model files and sidecars ===')
sets={}
for item in (i for i in records.values() if i['model']):
    path=Path(item['path'])
    match=re.fullmatch(r'(.+)-(\d{5})-of-(\d{5})(\.(?:gguf|safetensors|bin))',path.name,re.I)
    index=int(match[2]) if match else 0; expected=int(match[3]) if match else 0
    if not (match and 1<=index<=expected):
        sets[('file',item['actual'])]={'item':dict(item),'members':[item]}
        continue
    key=('set',str(path.parent),match[1],match[3],match[4])
    if key not in sets:sets[key]={'item':dict(item),'members':[],'indices':set(),'expected':expected,'pattern':str(path.parent/(match[1]+'-*-of-'+match[3]+match[4])),'first':index}
    group=sets[key];group['members'].append(item);group['indices'].add(index)
    if index<group['first']:group['item']=dict(item);group['first']=index
models=[]
for group in sets.values():
    item=group['item'];item['size']=sum(i['size'] for i in group['members'])
    item['refs']=set().union(*(i['refs'] for i in group['members']))
    item['shards']=group if 'expected' in group else None
    models.append(item)
models.sort(key=lambda i:i['size'],reverse=True)
for item in models[:LIMIT]:
    enrich(item)
    if item['role']=='cached model blob candidate' and not item['refs'] and item['format']=='unknown':continue
    group=item['shards']
    if group:
        missing=[n for n in range(1,group['expected']+1) if n not in group['indices']]
        print('\n  Model set: '+json.dumps(group['pattern'],ensure_ascii=False))
        print('  Shards: %s/%s present; %s'%(len(group['indices']),group['expected'],'missing: '+','.join('%05d'%n for n in missing[:20])+(' ...' if len(missing)>20 else '') if missing else 'complete filename set'))
        print('  Header file: '+json.dumps(item['path'],ensure_ascii=False))
    else:print('\n  File: '+json.dumps(item['path'],ensure_ascii=False))
    print('  Role: '+item['role']+'; format: '+item['format']+'; size: %.3f GiB'%(item['size']/2**30))
    print('  Model: '+item.get('name',Path(item['path']).name)+'; architecture: '+item['arch'])
    print('  Quant: '+item['quant']+('; filename hint: '+item['hint']+' [inferred]' if item['hint'] else ''))
    print('  Publisher/author: '+item['publisher']+'; repository: '+item['repo'])
    if item.get('quantizer'):print('  Quantizer: '+item['quantizer'])
    for key,value in item.get('mtp',{}).items():print('  MTP capability: '+clean(key)+'='+clean(value)+' [GGUF; not proof of a separate sidecar]')
    if item['dtype']:print('  Tensor dtypes: '+item['dtype']+' [header; not a quantization-method guarantee]')
    for ref in sorted(item['refs']):print('  Reference: '+clean(ref))
    if item['note']:print('  Metadata note: '+clean(item['note']))
if not models:print('  No recognized model files in the selected locations. Add --root for another store.')
if len(models)>LIMIT:print('  Model rows limited to %s of %s candidates; increase --model-limit.'%(LIMIT,len(models)))
for category in ['Backends','Gateways']:
    items=sorted((i for i in records.values() if i['category']==category),key=lambda i:i['size'],reverse=True)
    print('\n=== '+('Backend/runtime files' if category=='Backends' else 'Gateway/API frontend files')+' ===')
    for item in items[:100]:print('  '+item['role']+' ['+item['source']+']: '+json.dumps(item['path'],ensure_ascii=False))
    if not items:print('  No matching files in the selected locations; this does not prove the software is absent.')
    if len(items)>100:print('  Showing 100 of %s matching files.'%len(items))
for issue in issues[:20]:print('  INVENTORY ISSUE: '+clean(issue))
print('\nIdentity comes from bounded headers/manifests where available; filename/path roles are candidates.')
print('Repository/uploader, model author and quantizer are distinct. Unknown fields remain unknown.')
print('Per-file sizes are apparent lengths, which can exceed allocated disk use for sparse files.')
print('Model-set sizes sum discovered shards. Filename completeness does not validate tensor contents.')
print('No tensors are loaded, models hashed, services started, or gateway secrets read.')
AI_AUDIT_METADATA_PY
    [ "$?" -eq 0 ] && return
    printf '\nMetadata enrichment failed; using filename inventory.\n'
  fi
  printf '\n=== File inventory (filename evidence only) ===\n'
  printf 'Python 3 header inspection unavailable. Quant/publisher/architecture remain unknown.\n'
  while IFS= read -r -d '' path; do
    name=${path##*/}; role=
    case "$name" in
      *ngram*.bin|*ngram*.table|*n-gram*.bin) role='n-gram table candidate' ;;
      *mmproj*.gguf|*projector*.gguf) role='multimodal projector candidate' ;;
      *mtp*.gguf|*mtp*.bin) role='MTP sidecar candidate' ;;
      *.gguf|*.safetensors|*.onnx|*.pth|*.pt|*.ckpt|pytorch_model*.bin|adapter_model*.bin) role='model/weights candidate' ;;
      *cuda*.so*|*cublas*.so*|*hip*.so*|*rocblas*.so*|*vulkan*.so*|*ggml*.so*|*metal*.dylib|*.metallib) role='backend library candidate' ;;
      *gateway*.py|*proxy*.py|*frontdoor*.py|*litellm*.py) role='gateway/frontend candidate' ;;
    esac
    [ -n "$role" ] || continue
    if [[ "$name" =~ ^(.+)-([0-9]{5})-of-([0-9]{5})(\.(gguf|safetensors|bin))$ ]]; then
      index=$((10#${BASH_REMATCH[2]})); expected=$((10#${BASH_REMATCH[3]}))
      pattern="${path%/*}/${BASH_REMATCH[1]}-*-of-${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
      if [ "$index" -ge 1 ] && [ "$index" -le "$expected" ]; then
        slot=-1
        for ((j=0; j<${#shard_patterns[@]}; j++)); do [ "${shard_patterns[$j]}" = "$pattern" ] && slot=$j; done
        if [ "$slot" -lt 0 ]; then
          [ "$count" -ge "$MODEL_LIMIT" ] && continue
          slot=${#shard_patterns[@]}; shard_patterns[$slot]=$pattern; shard_counts[$slot]=0; shard_expected[$slot]=$expected; shard_indices[$slot]='|'
          count=$((count+1))
        fi
        shard_counts[$slot]=$((shard_counts[$slot]+1)); shard_indices[$slot]="${shard_indices[$slot]}$index|"
        continue
      fi
    fi
    [ "$count" -ge "$MODEL_LIMIT" ] && continue
    printf '  %s [filename]: %q\n' "$role" "$path"
    if [[ "$name" =~ (IQ[1-4]_[A-Za-z0-9_]+|Q[1-8]_[A-Za-z0-9_]+|BF16|F16|FP16|F32) ]]; then
      printf '    Quant filename hint: %s [inferred]; publisher: unknown\n' "${BASH_REMATCH[1]}"
    fi
    count=$((count+1))
  done < <(for ((i=1; i<${#args[@]}; i+=2)); do
    find "${args[$i]}" -xdev \( -name .git -o -name node_modules -o -name .venv -o -name site-packages -o -name .ssh -o -name secrets -o -name credentials \) -prune -o -type f -print0 2>/dev/null
  done)
  for ((j=0; j<${#shard_patterns[@]}; j++)); do
    printf '  Model set: %q\n' "${shard_patterns[$j]}"
    printf '  Shards: %s/%s present; ' "${shard_counts[$j]}" "${shard_expected[$j]}"
    missing=0
    for ((index=1; index<=${shard_expected[$j]}; index++)); do
      case "${shard_indices[$j]}" in *"|$index|"*) ;; *)
        [ "$missing" -eq 0 ] && printf 'missing: '
        [ "$missing" -lt 20 ] && printf '%05d ' "$index"
        missing=$((missing+1)) ;;
      esac
    done
    [ "$missing" -eq 0 ] && printf 'complete filename set'
    [ "$missing" -gt 20 ] && printf '...'
    printf '\n  Header identity and total size unavailable in filename-only mode.\n'
  done
  [ "$count" -ge "$MODEL_LIMIT" ] && printf '  Model row limit reached; additional models may be omitted.\n'
}
runtime_context() {
  local tool path any=false
  [ -d /System/Library/Frameworks/Metal.framework ] && printf '\nMetal GPU framework: /System/Library/Frameworks/Metal.framework [installed path]\n'
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
  printf '\nSelected %s distinct directories; %s nested locations included in their parents.\n' "${#SELECTED_PATHS[@]}" "$COVERED"
  if [ "$LIST_ROOTS" = true ]; then
    for ((i=0; i<${#SELECTED_PATHS[@]}; i++)); do printf 'ROOT\t%s\t%q\n' "${SELECTED_GROUPS[$i]}" "${SELECTED_PATHS[$i]}"; done
    for raw in "${ISSUES[@]}"; do printf 'ISSUE %q\n' "$raw"; done
    if [ "$DIAGNOSTICS" = true ]; then printf 'DIAGNOSTICS roots=%s traversals=0 filesystem_probes=%s\n' "${#SELECTED_PATHS[@]}" "$DEVICE_PROBES"; fi
    return
  fi
  for ((i=0; i<${#SELECTED_PATHS[@]}; i++)); do
    MEASUREMENTS=$((MEASUREMENTS+1))
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
  inventory
  runtime_context
  printf '\nFilesystem capacity for the scanned locations:\n'
  if command -v df >/dev/null 2>&1; then
    df -hP "$HOME" "${SELECTED_PATHS[@]}" 2>&1 | awk '!seen[$0]++'
    printf '\nFilesystem inode usage:\n'
    df -iP "$HOME" "${SELECTED_PATHS[@]}" 2>&1 | awk '!seen[$0]++'
  else printf 'df unavailable\n'; fi
  printf '\nDiscovery is limited to known locations and named AI folders. Use --root DIR for unlisted stores.\n'
  if [ "$DIAGNOSTICS" = true ]; then printf 'DIAGNOSTICS roots=%s traversals=%s filesystem_probes=%s\n' "${#SELECTED_PATHS[@]}" "$MEASUREMENTS" "$DEVICE_PROBES"; fi
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
