<#
Standalone Windows AI disk inventory. Compatible with Windows PowerShell 5.1
and PowerShell 7. No installation, service queries, or adjacent files required.
#>
[CmdletBinding()]
param(
    [switch]$Comprehensive,
    [switch]$Report,
    [string]$ReportPath,
    [string[]]$Root = @(),
    [string[]]$StorageRoot = @(),
    [string]$ModelRoot = $env:AI_AUDIT_MODEL_ROOT,
    [string]$StrataRoot = $env:AI_AUDIT_STRATA_ROOT,
    [switch]$HomeOnly,
    [switch]$ListRoots,
    [switch]$NoInventory,
    [ValidateRange(1,10000)][int]$ModelLimit = 500,
    [string]$GatewayRoot = $env:AI_AUDIT_GATEWAY_ROOT,
    [switch]$Diagnostics
)
$ErrorActionPreference = 'Stop'
if ($Report -and $ReportPath) { throw 'Use either -Report or -ReportPath, not both.' }
$watch = [Diagnostics.Stopwatch]::StartNew()
$targets = New-Object 'System.Collections.Generic.List[object]'
$issues = New-Object 'System.Collections.Generic.List[string]'
$seenText = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

# Compile once per PowerShell session. Enumerate cached filesystem metadata in
# .NET, avoiding a PowerShell provider object/pipeline operation per file.
$native = $true
if (-not ('AiDiskAuditInventoryV2.Scanner' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace AiDiskAuditInventoryV2 {
 public sealed class Result {
  public long Bytes, Files, Directories, Errors, SkippedLinks, OmittedAssets;
  public List<AiDiskAuditIdentityV1.Candidate> Assets=new List<AiDiskAuditIdentityV1.Candidate>();
  public Dictionary<string,int> AssetCounts=new Dictionary<string,int>();
  public void Capture(string path,long bytes) {
   if(path.StartsWith(@"\\?\UNC\"))path=@"\\"+path.Substring(8);
   else if(path.StartsWith(@"\\?\"))path=path.Substring(4);
   var c=AiDiskAuditIdentityV1.Reader.CandidateFor(path,bytes);if(c==null)return;
   int n;AssetCounts.TryGetValue(c.Kind,out n);
   if(n>=10000){OmittedAssets++;return;}AssetCounts[c.Kind]=n+1;Assets.Add(c);
  }
 }
 public static class Scanner {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern SafeFileHandle CreateFile(string name, uint access, uint share,
    IntPtr security, uint creation, uint flags, IntPtr template);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder text, uint size, uint flags);
  public static string Canonical(string path) {
   using(var handle=CreateFile(Path.GetFullPath(path),0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
    if(handle.IsInvalid) throw new IOException("Cannot resolve directory", Marshal.GetLastWin32Error());
    var buffer=new StringBuilder(32768);
    uint n=GetFinalPathNameByHandle(handle,buffer,(uint)buffer.Capacity,0);
    if(n==0 || n>=buffer.Capacity) throw new IOException("Cannot resolve directory");
    string value=buffer.ToString();
    if(value.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase)) value=@"\\"+value.Substring(8);
    else if(value.StartsWith(@"\\?\") && value.Length>5 && value[5]==':') value=value.Substring(4);
    string root=Path.GetPathRoot(value);
    return value.Length>root.Length ? value.TrimEnd('\\') : value;
   }
  }
  public static Result Measure(string path) { return Measure(path,false); }
  public static Result Measure(string path,bool inventory) {
   var result=new Result();
   var stack=new Stack<DirectoryInfo>();
   string extended=path.StartsWith(@"\\?\") ? path :
     path.StartsWith(@"\\") ? @"\\?\UNC\"+path.Substring(2) : @"\\?\"+path;
   stack.Push(new DirectoryInfo(extended));
   while(stack.Count!=0) {
    var dir=stack.Pop();
    try {
     foreach(var entry in dir.EnumerateFileSystemInfos()) {
      try {
       if((entry.Attributes & FileAttributes.ReparsePoint)!=0) {
        result.SkippedLinks++;
        if(inventory && entry is FileInfo && AiDiskAuditIdentityV1.Reader.Safe(entry.FullName)) {
         string actual=Canonical(entry.FullName);
         if(AiDiskAuditIdentityV1.Reader.Safe(actual))result.Capture(entry.FullName,new FileInfo(actual).Length);
        }
        continue;
       }
       var child=entry as DirectoryInfo;
       if(child!=null) stack.Push(child);
       else { long size=((FileInfo)entry).Length; result.Bytes+=size; result.Files++; if(inventory)result.Capture(entry.FullName,size); }
      } catch(IOException) { result.Errors++; }
        catch(UnauthorizedAccessException) { result.Errors++; }
     }
     result.Directories++;
    } catch(IOException) { result.Errors++; }
      catch(UnauthorizedAccessException) { result.Errors++; }
   }
   return result;
  }
 }
}
namespace AiDiskAuditIdentityV1 {
 public sealed class Candidate { public string Path,Kind; public long Bytes; }
 public sealed class Identity {
  public string Format="unknown",Role="model/weights candidate",Source="filename",Note="",HeaderJson="";
  public System.Collections.Generic.Dictionary<string,string> Meta=new System.Collections.Generic.Dictionary<string,string>();
 }
 public static class Reader {
  const long MaxHeader=8*1024*1024, MaxMetadata=256*1024*1024;
  static readonly System.Text.RegularExpressions.Regex ModelExt=new System.Text.RegularExpressions.Regex(@"\.(gguf|safetensors|onnx|pt|pth|ckpt|tflite|npz|mlmodel)$",System.Text.RegularExpressions.RegexOptions.IgnoreCase);
  static readonly System.Text.RegularExpressions.Regex Backend=new System.Text.RegularExpressions.Regex(@"(ggml|cuda|cudnn|cublas|amdhip|hipblas|hiprtc|rocblas|vulkan|directml|mlx|metal).*\.(so(?:\..*)?|dll|dylib|metallib|metal)$",System.Text.RegularExpressions.RegexOptions.IgnoreCase);
  static readonly System.Text.RegularExpressions.Regex Gateway=new System.Text.RegularExpressions.Regex(@"(gateway|proxy|litellm|frontdoor|openai[-_]server).*\.(py|js|sh|ps1|exe)$",System.Text.RegularExpressions.RegexOptions.IgnoreCase);
  public static Candidate CandidateFor(string path,long size) {
   string name=System.IO.Path.GetFileName(path).ToLowerInvariant();
   string normal=path.Replace('\\','/').ToLowerInvariant(); string kind=null;
   if(ModelExt.IsMatch(name) || ((name.Contains("mmproj")||name.Contains("projector")||name.Contains("ngram")||name.Contains("n-gram")||name.Contains("-mtp")) && name.EndsWith(".bin")) || ((name.StartsWith("pytorch_model")||name.StartsWith("adapter_model"))&&name.EndsWith(".bin")))kind="Model";
   else if(normal.Contains("/blobs/") && System.Text.RegularExpressions.Regex.IsMatch(name,@"^(sha256-)?[a-f0-9]{40,64}$"))kind="Model";
   else if(Backend.IsMatch(name)||name=="llama-server.exe"||name=="ollama.exe")kind="Backend";
   else if(Gateway.IsMatch(name)&&!normal.Contains("/tests/")&&!normal.Contains("/examples/")&&!normal.Contains("/site-packages/")&&!normal.Contains("/node_modules/"))kind="Gateway";
   else if(normal.Contains("/manifests/") && size<=1024*1024 && !name.EndsWith(".env") && !name.Contains("secret") && !name.Contains("token"))kind="Manifest";
   return kind==null?null:new Candidate{Path=path,Kind=kind,Bytes=size};
  }
  public static string FileType(string value) {
   string[] names={"F32","F16","Q4_0","Q4_1","","","","Q8_0","Q5_0","Q5_1","Q2_K","Q3_K_S","Q3_K_M","Q3_K_L","Q4_K_S","Q4_K_M","Q5_K_S","Q5_K_M","Q6_K","IQ2_XXS","IQ2_XS","Q2_K_S","IQ3_XS","IQ3_XXS","IQ1_S","IQ4_NL","IQ3_S","IQ3_M","IQ2_S","IQ2_M","IQ4_XS","IQ1_M","BF16","","","","TQ1_0","TQ2_0","MXFP4_MOE","NVFP4","Q1_0","Q2_0"};
   int index;return int.TryParse(value,out index)&&index>=0&&index<names.Length&&names[index]!=""?names[index]:"file_type="+value;
  }
  public static bool Safe(string path) {
   string n="/"+path.Replace('\\','/').ToLowerInvariant()+"/";
   foreach(string s in new[]{"/.ssh/","/.gnupg/","/credentials/","/secrets/","/.env/"})if(n.Contains(s))return false;
   return !path.EndsWith(".pem",System.StringComparison.OrdinalIgnoreCase)&&!path.EndsWith(".key",System.StringComparison.OrdinalIgnoreCase);
  }
  static ulong UInt(System.IO.BinaryReader r,int n,bool big) {
   byte[] b=r.ReadBytes(n);if(b.Length!=n)throw new System.IO.InvalidDataException("truncated metadata");
   ulong v=0;
   if(big){for(int i=0;i<n;i++)v=(v<<8)|b[i];}
   else{for(int i=n-1;i>=0;i--)v=(v<<8)|b[i];}
   return v;
  }
  static void Skip(System.IO.BinaryReader r,ulong n) {
   if(n>(ulong)MaxMetadata || r.BaseStream.Position+(long)n>System.Math.Min(r.BaseStream.Length,MaxMetadata))throw new System.IO.InvalidDataException("metadata limit/truncation");
   r.BaseStream.Seek((long)n,System.IO.SeekOrigin.Current);
  }
  static string Text(System.IO.BinaryReader r,bool big,bool keep) {
   ulong n=UInt(r,8,big);
   if(!keep||n>4096){Skip(r,n);return "";}
   if(r.BaseStream.Position+(long)n>MaxMetadata)throw new System.IO.InvalidDataException("metadata string limit");
   byte[] b=r.ReadBytes((int)n);if(b.Length!=(int)n)throw new System.IO.InvalidDataException("truncated string");
   return System.Text.Encoding.UTF8.GetString(b);
  }
  static string Value(System.IO.BinaryReader r,uint type,bool big,bool keep,int depth,ref int steps) {
   if(++steps>2000000||depth>2)throw new System.IO.InvalidDataException("metadata item limit");
   int[] sizes={1,1,2,2,4,4,4,1,0,0,8,8,8};
   if(type==8)return Text(r,big,keep);
   if(type==9){
    uint sub=(uint)UInt(r,4,big);ulong count=UInt(r,8,big);
    if(count>2000000)throw new System.IO.InvalidDataException("metadata array limit");
    if(sub<sizes.Length&&sizes[sub]!=0)Skip(r,count*(ulong)sizes[sub]);
    else for(ulong i=0;i<count;i++)Value(r,sub,big,false,depth+1,ref steps);
    return "";
   }
   if(type>=sizes.Length||sizes[type]==0)throw new System.IO.InvalidDataException("unknown metadata type");
   if(!keep){Skip(r,(ulong)sizes[type]);return "";}
   return UInt(r,sizes[type],big).ToString(System.Globalization.CultureInfo.InvariantCulture);
  }
  public static Identity Inspect(string path) {
   var item=new Identity();string name=System.IO.Path.GetFileName(path).ToLowerInvariant();
   item.Format=System.IO.Path.GetExtension(path).TrimStart('.').ToUpperInvariant();
   if(name.Contains("ngram")||name.Contains("n-gram"))item.Role="n-gram table candidate";
   else if(name.Contains("mmproj")||name.Contains("projector"))item.Role="multimodal projector candidate";
   else if(System.Text.RegularExpressions.Regex.IsMatch(name,@"(^|[-_.])mtp([-_.]|$)"))item.Role="MTP sidecar candidate";
   try {
    if(!Safe(path)||!Safe(AiDiskAuditInventoryV2.Scanner.Canonical(path)))throw new System.IO.InvalidDataException("sensitive target excluded");
    using(var f=new System.IO.FileStream(path,System.IO.FileMode.Open,System.IO.FileAccess.Read,System.IO.FileShare.ReadWrite|System.IO.FileShare.Delete))
    using(var r=new System.IO.BinaryReader(f)){
     string magic=System.Text.Encoding.ASCII.GetString(r.ReadBytes(4));
     if(magic=="GGUF"||magic=="FUGG"){
      item.Format="GGUF";ulong version=UInt(r,4,false);bool big=false;
      if(version!=2&&version!=3){f.Position=4;version=UInt(r,4,true);big=true;}
      if(version!=2&&version!=3)throw new System.IO.InvalidDataException("unsupported GGUF version");
      UInt(r,8,big);ulong count=UInt(r,8,big);if(count>100000)throw new System.IO.InvalidDataException("metadata key limit");
      int steps=0;
      for(ulong i=0;i<count;i++){
       string key=Text(r,big,true);uint type=(uint)UInt(r,4,big);
       bool keep=key=="general.name"||key=="general.author"||key=="general.organization"||key=="general.architecture"||key=="general.type"||key=="general.file_type"||key=="general.quantized_by"||key=="clip.projector_type"||key.EndsWith(".nextn_predict_layers");
       string value=Value(r,type,big,keep,0,ref steps);if(keep&&value!="")item.Meta[key]=value;
      }
      if(item.Meta.ContainsKey("clip.projector_type")||(item.Meta.ContainsKey("general.type")&&item.Meta["general.type"]=="mmproj")||(item.Meta.ContainsKey("general.architecture")&&(item.Meta["general.architecture"]=="clip"||item.Meta["general.architecture"]=="mmproj"))){item.Role="multimodal projector/encoder [GGUF]";item.Source="GGUF";}
      else if(item.Meta.ContainsKey("general.type")&&item.Meta["general.type"]=="mtp"){item.Role="MTP sidecar [GGUF]";item.Source="GGUF";}
     }else if(item.Format=="GGUF")item.Note="GGUF extension but invalid/missing GGUF magic";
     else if(item.Format=="SAFETENSORS"||item.Format==""){
      f.Position=0;ulong n=UInt(r,8,false);
      if(n<2||n>(ulong)MaxHeader||f.Position+(long)n>f.Length)throw new System.IO.InvalidDataException("safetensors header limit/unknown blob format");
      item.HeaderJson=System.Text.Encoding.UTF8.GetString(r.ReadBytes((int)n));
     }
    }
   }catch(System.Exception e){item.Note=e.Message;}
   return item;
  }
 }
}
'@ -ErrorAction Stop
    } catch { $native = $false; $issues.Add('Native metadata scanner unavailable; using the provider fallback.') }
}

function Add-AuditRoot([string]$Category, [string]$Path, [bool]$Required = $false) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try { $pathText = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) } catch { $issues.Add("Invalid configured path: $Path"); return }
    if (-not [IO.Directory]::Exists($pathText)) {
        if ($Required) { $issues.Add("Missing/inaccessible configured directory: $pathText") }
        return
    }
    if (-not $seenText.Add($pathText)) { return }
    $targets.Add([pscustomobject]@{Category=$Category; Path=$pathText})
}
function Add-ConfiguredRoot([string]$Category, [string]$Variable, [string]$Default) {
    $value = [Environment]::GetEnvironmentVariable($Variable)
    if ($value) { Add-AuditRoot $Category $value $true } else { Add-AuditRoot $Category $Default }
}
function Join-Base([string]$Base, [string]$Child) {
    if ($Base) { return [IO.Path]::Combine($Base, $Child) }
    return ''
}
function Test-AiName([string]$Name) {
    return $Name -match '(?i)(^ai$|model|^strata|^llama|^vllm|^sglang|comfy|unsloth|^hf-cache|huggingface|^lmstudio|^ollama|^llm|[-_]llm|rocm|^stable-diffusion|gateway|litellm|hermes|open-webui|local-ai)'
}
function Find-AiDirectories([string]$Parent, [int]$Depth = 1) {
    if (-not [IO.Directory]::Exists($Parent)) { return }
    try {
        foreach ($path in [IO.Directory]::EnumerateDirectories($Parent)) {
            $name = [IO.Path]::GetFileName($path)
            if (Test-AiName $name) { Add-AuditRoot 'Workspace' $path }
            elseif ($Depth -gt 1) { Find-AiDirectories $path ($Depth-1) }
        }
    } catch { $issues.Add("Discovery incomplete: $Parent") }
}
function Measure-Provider([string]$Path) {
    $result = [pscustomobject]@{Bytes=[long]0;Files=[long]0;Directories=[long]0;Errors=[long]0;SkippedLinks=[long]0;Assets=(New-Object 'System.Collections.Generic.List[object]');OmittedAssets=0}
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count) {
        $dir = $stack.Pop()
        $scanErrors = @()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue -ErrorVariable scanErrors)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $result.SkippedLinks++; continue }
            if ($item.PSIsContainer) { $stack.Push($item.FullName) }
            else {
                $result.Bytes += $item.Length; $result.Files++
                if(-not $NoInventory -and $item.Name -match '(?i)\.(gguf|safetensors|onnx|pt|pth|ckpt)$|(?:mmproj|mtp|ngram).*\.bin$') {
                    if($result.Assets.Count -lt 10000){$result.Assets.Add([pscustomobject]@{Path=$item.FullName;Kind='Model';Bytes=$item.Length})}else{$result.OmittedAssets++}
                }
            }
        }
        $result.Errors += $scanErrors.Count; $result.Directories++
    }
    return $result
}

function Read-ModelJson([string]$Path) {
    try {
        if (-not [AiDiskAuditIdentityV1.Reader]::Safe($Path) -or -not [AiDiskAuditIdentityV1.Reader]::Safe([AiDiskAuditInventoryV2.Scanner]::Canonical($Path))) { return $null }
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        try {
            if ($stream.Length -gt 1MB) { return $null }
            $reader=New-Object IO.BinaryReader($stream)
            $bytes=$reader.ReadBytes([int][Math]::Min($stream.Length,1MB))
            return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop)
        } finally { $stream.Dispose() }
    } catch { return $null }
}
function Safe-IdentityText($Value) {
    $text=[regex]::Replace([string]$Value,'[\x00-\x1f\x7f]','?')
    if ($text.Length -gt 240) { return $text.Substring(0,240) }
    return $text
}
function Add-AssetInventory($Lines,$Assets,[int]$Limit,[bool]$NativeAvailable) {
    $Lines.Add(''); $Lines.Add('=== Model files and sidecars ===')
    if (-not $NativeAvailable) {
        $Lines.Add('Header inspection unavailable; filename/path classification only.')
        foreach($entry in @($Assets | Where-Object {$_.Kind -eq 'Model'} | Sort-Object Bytes -Descending | Select-Object -First $Limit)) {
            $Lines.Add("  File: $($entry.Path)")
            $Lines.Add('  Role/quant/publisher: unknown; native metadata reader unavailable.')
        }
        return
    }
    $references=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in @($Assets | Where-Object {$_.Kind -eq 'Manifest'})) {
        $normal=$entry.Path.Replace('/','\');$offset=$normal.LastIndexOf('\manifests\',[StringComparison]::OrdinalIgnoreCase)
        if($offset -lt 0){continue}
        $base=$normal.Substring(0,$offset);$blobs=Join-Path $base 'blobs'
        if(-not [IO.Directory]::Exists($blobs)){continue}
        $manifest=Read-ModelJson $entry.Path
        if(-not $manifest -or -not $manifest.layers){continue}
        foreach($layer in $manifest.layers) {
            if([string]$layer.mediaType -notmatch 'image\.(model|projector|adapter|tensor)'){continue}
            if([string]$layer.digest -notmatch '^sha256:[a-f0-9]{64}$'){continue}
            $path=[IO.Path]::Combine($blobs,(([string]$layer.digest).Replace(':','-')))
            try{$physical=[AiDiskAuditInventoryV2.Scanner]::Canonical($path)}catch{continue}
            $reference='Ollama manifest: '+$normal.Substring($offset+11)
            if($references.ContainsKey($physical)){$references[$physical]+='; '+$reference}else{$references.Add($physical,$reference)}
        }
    }
    $models=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in @($Assets | Where-Object {$_.Kind -eq 'Model'} | Sort-Object Bytes -Descending)) {
        try{$physical=[AiDiskAuditInventoryV2.Scanner]::Canonical($entry.Path)}catch{continue}
        if(-not [AiDiskAuditIdentityV1.Reader]::Safe($physical)){continue}
        if(-not $models.ContainsKey($physical)){$models.Add($physical,$entry)}
        elseif([IO.Path]::GetExtension($models[$physical].Path) -eq '' -and [IO.Path]::GetExtension($entry.Path) -ne ''){$models[$physical]=$entry}
    }
    $configCache=@{}; $shardCache=@{}; $shown=0
    foreach($pair in @($models.GetEnumerator() | Sort-Object {$_.Value.Bytes} -Descending | Select-Object -First $Limit)) {
        $entry=$pair.Value;$path=$entry.Path;$identity=[AiDiskAuditIdentityV1.Reader]::Inspect($path)
        $first=[regex]::Replace($path,'-\d{5}-of-(\d{5})\.gguf$','-00001-of-$1.gguf')
        if($first -ne $path -and [IO.File]::Exists($first) -and -not $identity.Meta.ContainsKey('general.file_type')) {
            if(-not $shardCache.ContainsKey($first)){$shardCache[$first]=[AiDiskAuditIdentityV1.Reader]::Inspect($first)}
            foreach($key in $shardCache[$first].Meta.Keys){if(-not $identity.Meta.ContainsKey($key)){$identity.Meta[$key]=$shardCache[$first].Meta[$key]}}
            $identity.Note+='; missing identity fields inherited from first-shard GGUF header; tensors not validated'
        }
        $meta=$identity.Meta;$quant='unknown';$publisher='unknown';$repo='unknown';$dtype='';$arch='unknown';$modelName=[IO.Path]::GetFileName($path)
        if($meta.ContainsKey('general.name')){$modelName=Safe-IdentityText $meta['general.name']}
        if($meta.ContainsKey('general.architecture')){$arch=Safe-IdentityText $meta['general.architecture']}
        if($meta.ContainsKey('general.file_type')){$quant=[AiDiskAuditIdentityV1.Reader]::FileType($meta['general.file_type'])+' [GGUF]'}
        if($meta.ContainsKey('general.organization')){$publisher=(Safe-IdentityText $meta['general.organization'])+' [GGUF declared]'}
        elseif($meta.ContainsKey('general.author')){$publisher=(Safe-IdentityText $meta['general.author'])+' [GGUF declared]'}
        if($identity.HeaderJson){
            try{
                $header=$identity.HeaderJson|ConvertFrom-Json -ErrorAction Stop
                $types=@($header.PSObject.Properties | Where-Object {$_.Name -ne '__metadata__' -and $_.Value.dtype -and $null -ne $_.Value.shape -and $_.Value.data_offsets.Count -eq 2} | ForEach-Object {$_.Value.dtype} | Sort-Object -Unique)
                if($types.Count){$dtype=$types -join ',';$identity.Format='SAFETENSORS'}else{$identity.Note='No valid safetensors descriptors'}
            }catch{$identity.Note='Invalid safetensors JSON header'}
            $identity.HeaderJson=''
        }
        if(-not $identity.Format -and -not $references.ContainsKey($pair.Key)){continue}
        $normal=$path.Replace('\','/')
        $match=[regex]::Match($normal,'models--([^/]+)')
        if($match.Success){$node=$match.Groups[1].Value;$split=$node.IndexOf('--');$repo=if($split -ge 0){$node.Substring(0,$split)+'/'+$node.Substring($split+2)}else{$node};$repo+=' [cache path; uploader, not verified publisher]'}
        else {
            $match=[regex]::Match($normal,'(?i)/\.lmstudio/models/([^/]+)/([^/]+)/')
            if($match.Success){$repo=$match.Groups[1].Value+'/'+$match.Groups[2].Value+' [LM Studio path]'}
        }
        $configPath=Join-Path ([IO.Path]::GetDirectoryName($path)) 'config.json'
        if(-not $configCache.ContainsKey($configPath)){$configCache[$configPath]=Read-ModelJson $configPath}
        $config=$configCache[$configPath]
        if($config){
            $q=$config.quantization_config
            if($q -and $q.quant_method -and $quant -eq 'unknown'){$quant=(Safe-IdentityText $q.quant_method)+$(if($q.bits){' '+$q.bits+'-bit'}else{''})+' [config]'}
            if($arch -eq 'unknown' -and $config.model_type){$arch=(Safe-IdentityText $config.model_type)+' [config]'}
        }
        $hint=[regex]::Match([IO.Path]::GetFileName($path),'(?i)(?:UD-)?(?:IQ[1-4]_[A-Z0-9_]+|Q[1-8](?:_[A-Z0-9]+)+|TQ[12]_0|BF16|F16|FP16|F32|FP32|FP8|MXFP4(?:_MOE)?|NVFP4)')
        $Lines.Add('');$Lines.Add('  File: '+(Safe-IdentityText $path))
        $Lines.Add('  Role: '+$identity.Role+'; format: '+$identity.Format+'; size: '+($entry.Bytes/1GB).ToString('F3',[Globalization.CultureInfo]::InvariantCulture)+' GiB')
        $Lines.Add('  Model: '+$modelName+'; architecture: '+$arch)
        $Lines.Add('  Quant: '+$quant+$(if($hint.Success){'; filename hint: '+$hint.Value+' [inferred]'}else{''}))
        $Lines.Add('  Publisher/author: '+$publisher+'; repository: '+(Safe-IdentityText $repo))
        if($meta.ContainsKey('general.quantized_by')){$Lines.Add('  Quantizer: '+(Safe-IdentityText $meta['general.quantized_by'])+' [GGUF declared]')}
        foreach($key in $meta.Keys){if($key.EndsWith('.nextn_predict_layers')){$Lines.Add('  MTP capability: '+$key+'='+$meta[$key]+' [GGUF; not proof of a separate sidecar]')}}
        if($dtype){$Lines.Add('  Tensor dtypes: '+$dtype+' [header; not a quantization-method guarantee]')}
        if($references.ContainsKey($pair.Key)){$Lines.Add('  Reference: '+$references[$pair.Key])}
        if($identity.Note){$Lines.Add('  Metadata note: '+(Safe-IdentityText $identity.Note))}
        $shown++
    }
    if(-not $shown){$Lines.Add('  No recognized model files in selected locations. Add -Root for another store.')}
    if($models.Count -gt $Limit){$Lines.Add("  Model rows limited to $Limit of $($models.Count) candidates; increase -ModelLimit.")}
    $Lines.Add('');$Lines.Add('=== Backend/runtime files ===')
    $backendEntries=@($Assets | Where-Object {$_.Kind -eq 'Backend'} | Sort-Object Bytes -Descending)
    foreach($entry in @($backendEntries | Select-Object -First 100)) {
        $name=[IO.Path]::GetFileName($entry.Path)
        $backend=if($name -match 'hip|rocblas|rocm'){'ROCm/HIP'}elseif($name -match 'cuda|cudnn|cublas'){'CUDA'}elseif($name -match 'vulkan'){'Vulkan'}elseif($name -match 'metal|mlx'){'Metal/MLX'}elseif($name -match 'directml'){'DirectML'}else{'GGML/CPU/inference runtime'}
        $Lines.Add("  $backend [filename/path]: "+(Safe-IdentityText $entry.Path))
    }
    if(-not $backendEntries.Count){$Lines.Add('  No matching backend files in the selected locations; not proof of absence.')}
    $Lines.Add('');$Lines.Add('=== Gateway/API frontend files ===')
    $gateways=@($Assets | Where-Object {$_.Kind -eq 'Gateway'} | Sort-Object Bytes -Descending)
    foreach($entry in @($gateways|Select-Object -First 100)){$Lines.Add('  Gateway/frontend candidate [filename/path]: '+(Safe-IdentityText $entry.Path))}
    if(-not $gateways.Count){$Lines.Add('  No matching gateway files in the selected locations; not proof of absence.')}
    $Lines.Add('Identity comes from bounded headers/manifests where available; filename/path roles are candidates.')
    $Lines.Add('Repository/uploader, model author and quantizer are distinct. Unknown fields remain unknown.')
    $Lines.Add('No tensors are loaded, models hashed, services started or gateway secrets read.')
}

$homeDir = $env:USERPROFILE
if (-not $homeDir) { $homeDir = [Environment]::GetFolderPath('UserProfile') }
$cache = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Base $homeDir '.cache' }
$hf = if ($env:HF_HOME) { $env:HF_HOME } else { Join-Base $cache 'huggingface' }
$localData=$env:LOCALAPPDATA; $roaming=$env:APPDATA
Add-AuditRoot 'Gateway' $GatewayRoot ([bool]$GatewayRoot)
foreach ($name in '.hermes','litellm','open-webui','local-ai') { Add-AuditRoot 'Gateway' (Join-Base $homeDir $name) }
foreach ($name in '.lmstudio','.ollama','.continue','.aitk') { Add-AuditRoot 'Models/apps' (Join-Base $homeDir $name) }
# Selected redirected stores remain roots even when their parent is an app root.
Add-AuditRoot 'Models' (Join-Base $homeDir '.lmstudio\models')
Add-ConfiguredRoot 'Models' 'OLLAMA_MODELS' (Join-Base $homeDir '.ollama\models')
Add-ConfiguredRoot 'Cache' 'HF_HOME' (Join-Base $cache 'huggingface')
$hubDefault=Join-Base $hf 'hub'
if ($env:HUGGINGFACE_HUB_CACHE) { $hubDefault=$env:HUGGINGFACE_HUB_CACHE }
Add-ConfiguredRoot 'Cache' 'HF_HUB_CACHE' $hubDefault
Add-ConfiguredRoot 'Cache' 'HF_DATASETS_CACHE' (Join-Base $hf 'datasets')
Add-ConfiguredRoot 'Cache' 'HF_XET_CACHE' (Join-Base $hf 'xet')
Add-ConfiguredRoot 'Cache' 'HF_ASSETS_CACHE' (Join-Base $hf 'assets')
Add-ConfiguredRoot 'Cache' 'TORCH_HOME' (Join-Base $cache 'torch')
Add-ConfiguredRoot 'Cache' 'UV_CACHE_DIR' (Join-Base $localData 'uv\cache')
Add-ConfiguredRoot 'Cache' 'PIP_CACHE_DIR' (Join-Base $localData 'pip\Cache')
Add-ConfiguredRoot 'Cache' 'TRITON_CACHE_DIR' (Join-Base $homeDir '.triton\cache')
Add-ConfiguredRoot 'Cache' 'CUDA_CACHE_PATH' (Join-Base $localData 'NVIDIA\ComputeCache')
Add-ConfiguredRoot 'Cache' 'VLLM_CACHE_ROOT' (Join-Base $cache 'vllm')
Add-ConfiguredRoot 'Environments' 'UV_PYTHON_INSTALL_DIR' (Join-Base $roaming 'uv\data\python')
Add-ConfiguredRoot 'Environments' 'UV_TOOL_DIR' (Join-Base $roaming 'uv\tools')
foreach ($name in 'comgr','torch_extensions','sglang','flashinfer','unsloth','llama.cpp','mlx') {
    Add-AuditRoot 'Cache' (Join-Base $cache $name)
}
foreach ($name in 'npm-cache','AMD\DxCache','AMD\GLCache','NVIDIA\DXCache','NVIDIA\GLCache',
                  'Microsoft\FoundryLocal','Programs\Ollama','LM Studio','puccinialin','onnxruntime','OpenVINO') {
    Add-AuditRoot 'Apps/cache' (Join-Base $localData $name)
}
foreach ($name in '.unsloth','.conda','.venvs','venvs','miniconda3','anaconda3','miniforge3') {
    Add-AuditRoot 'Environments' (Join-Base $homeDir $name)
}
foreach ($name in 'AI','Models','llm') { Add-AuditRoot 'Workspace' (Join-Base $homeDir $name) }
foreach ($parent in @($homeDir,(Join-Base $homeDir 'projects'),(Join-Base $homeDir 'src'),(Join-Base $homeDir 'Documents'))) {
    Find-AiDirectories $parent
}
if (-not $HomeOnly) {
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -eq [IO.DriveType]::Fixed -and $drive.IsReady) { Find-AiDirectories $drive.RootDirectory.FullName }
    }
    foreach ($path in @((Join-Base $env:ProgramData 'Ollama'),(Join-Base $env:ProgramData 'Microsoft\WindowsAI'))) {
        Add-AuditRoot 'System models' $path
    }
}
foreach ($path in $StorageRoot) { Find-AiDirectories $path 2 }
foreach ($path in $Root) { Add-AuditRoot 'Custom' $path $true }
if ($ModelRoot) { Add-AuditRoot 'Models' $ModelRoot $true }
if ($StrataRoot) { Add-AuditRoot 'Workspace' $StrataRoot $true }
if ($Comprehensive) {
    foreach ($name in '.cargo','.rustup','.docker','.vscode') { Add-AuditRoot 'Toolchains' (Join-Base $homeDir $name) }
    foreach ($path in @((Join-Base $roaming 'Python'),(Join-Base $localData 'Programs\Python'))) { Add-AuditRoot 'Python' $path }
    if (-not $HomeOnly) {
        foreach ($name in 'NVIDIA GPU Computing Toolkit','AMD\ROCm','AMD\RyzenAI','AMD\VitisAI','Intel\OpenVINO','Qualcomm') {
            Add-AuditRoot 'SDKs' (Join-Base $env:ProgramFiles $name)
        }
        Add-ConfiguredRoot 'SDKs' 'CUDA_PATH' ''
        foreach ($name in 'Docker','NVIDIA Corporation','AMD','Intel','Qualcomm') {
            Add-AuditRoot 'System data' (Join-Base $env:ProgramData $name)
        }
    }
}

$physical = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($target in $targets) {
    try {
        if ($native) { $path=[AiDiskAuditInventoryV2.Scanner]::Canonical($target.Path) }
        else {
            $item=Get-Item -LiteralPath $target.Path -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Cannot resolve link in fallback mode' }
            $path=$item.FullName
        }
        if (-not $physical.ContainsKey($path)) { $physical.Add($path,[pscustomobject]@{Category=$target.Category;Path=$path}) }
    } catch { $issues.Add("Cannot resolve directory: $($target.Path)") }
}
$selected = New-Object 'System.Collections.Generic.List[object]'
$parents = New-Object 'System.Collections.Generic.List[string]'
$covered=0
foreach ($target in @($physical.Values | Sort-Object @{Expression={$_.Path.Length}},Path)) {
    $nested=$false
    foreach ($parent in $parents) {
        $prefix=$parent.TrimEnd('\')+'\'
        if ($target.Path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { $nested=$true; break }
    }
    if ($nested) { $covered++; continue }
    $parents.Add($target.Path); $selected.Add($target)
}
$lines = New-Object 'System.Collections.Generic.List[string]'
$lines.Add('AI Disk Auditor - Windows')
$lines.Add('Read-only inventory. No service calls, cleanup, or installation.')
$lines.Add("Distinct roots: $($selected.Count); nested roots covered by parents: $covered")
$results = New-Object 'System.Collections.Generic.List[object]'
$assets=New-Object 'System.Collections.Generic.List[object]'
$omittedAssets=[long]0
$fileCount=[long]0; $dirCount=[long]0; $skipped=[long]0
foreach ($target in $selected) {
    if ($ListRoots) { $lines.Add("ROOT`t$($target.Category)`t$($target.Path)"); continue }
    if ($native) { $measurement=[AiDiskAuditInventoryV2.Scanner]::Measure($target.Path,(-not $NoInventory)) }
    else { $measurement=Measure-Provider $target.Path }
    if (-not $NoInventory) {
        foreach($asset in $measurement.Assets){$assets.Add($asset)}
        $omittedAssets+=$measurement.OmittedAssets
    }
    $status=if ($measurement.Errors -gt 0 -and $measurement.Directories -eq 0 -and $measurement.Files -eq 0) {'UNREADABLE'} elseif ($measurement.Errors -gt 0) {'PARTIAL'} else {'OK'}
    $results.Add([pscustomobject]@{Bytes=$measurement.Bytes;Status=$status;Category=$target.Category;Path=$target.Path;Errors=$measurement.Errors})
    $fileCount+=$measurement.Files; $dirCount+=$measurement.Directories; $skipped+=$measurement.SkippedLinks
}
if (-not $ListRoots) {
    $lines.Add(''); $lines.Add('SIZE (GiB)  STATUS    CATEGORY       DIRECTORY')
    foreach ($item in @($results | Sort-Object Bytes -Descending)) {
        $size=if ($item.Status -eq 'UNREADABLE') {'?'} elseif ($item.Bytes -eq 0) {'0'} elseif ($item.Bytes -lt 0.01GB) {'<0.01'} else {($item.Bytes/1GB).ToString('F2',[Globalization.CultureInfo]::InvariantCulture)}
        $safe=$item.Path.Replace("`r",'\r').Replace("`n",'\n').Replace("`t",'\t')
        $lines.Add(('{0,10}  {1,-8}  {2,-13}  {3}' -f $size,$item.Status,$item.Category,$safe))
        if ($item.Errors) { $lines.Add("            $($item.Errors) inaccessible/changing entries; bytes shown are incomplete.") }
    }
    $lines.Add(''); $lines.Add('Sizes are apparent file lengths, not allocated disk blocks or reclaimable totals.')
    $lines.Add('File lengths are counted per entry; hard links can count repeatedly. Interior links/junctions are not traversed.')
    $lines.Add("Skipped interior reparse points: $skipped (redirected stores can be included with -Root).")
}
if (-not $ListRoots -and -not $NoInventory) {
    if (-not $HomeOnly -and $native) {
        foreach($name in 'vulkan-1.dll','nvcuda.dll','DirectML.dll') {
            $path=Join-Base $env:SystemRoot ('System32\'+$name)
            if([IO.File]::Exists($path)){$assets.Add([AiDiskAuditIdentityV1.Reader]::CandidateFor($path,([IO.FileInfo]$path).Length))}
        }
    }
    Add-AssetInventory $lines $assets $ModelLimit $native
    if($omittedAssets){$lines.Add("Inventory candidate cap reached: $omittedAssets omitted; use a narrower -Root.")}
}
foreach ($issue in $issues) { $lines.Add("ISSUE: $issue") }
if ($Diagnostics) {
    $lines.Add("DIAGNOSTICS roots=$($selected.Count) traversals=$(if($ListRoots){0}else{$selected.Count}) files=$fileCount directories=$dirCount scanner=$(if($native){'dotnet'}else{'provider'}) elapsed_ms=$($watch.ElapsedMilliseconds)")
}
if ($Report -or $ReportPath) {
    if (-not $ReportPath) {
        $reportDir=Join-Base $homeDir 'AI-Disk-Audit-Reports'
        [IO.Directory]::CreateDirectory($reportDir) | Out-Null
        $ReportPath=Join-Base $reportDir ('ai-disk-audit_'+(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')+'.txt')
    }
    $ReportPath=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)
    $stream=New-Object IO.FileStream($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {
        $writer=New-Object IO.StreamWriter($stream)
        try { foreach ($line in $lines) { $writer.WriteLine($line) } } finally { $writer.Dispose() }
    } finally { $stream.Dispose() }
    $lines.Add("Report saved to: $ReportPath")
}
$lines | Write-Output
