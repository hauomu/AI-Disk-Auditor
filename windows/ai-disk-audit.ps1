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
if (-not ('AiDiskAuditPortable.Scanner' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace AiDiskAuditPortable {
 public sealed class Result {
  public long Bytes, Files, Directories, Errors, SkippedLinks;
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
  public static Result Measure(string path) {
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
       if((entry.Attributes & FileAttributes.ReparsePoint)!=0) { result.SkippedLinks++; continue; }
       var child=entry as DirectoryInfo;
       if(child!=null) stack.Push(child);
       else { result.Bytes+=((FileInfo)entry).Length; result.Files++; }
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
    return $Name -match '(?i)(^ai$|model|^strata|^llama|^vllm|^sglang|comfy|unsloth|^hf-cache|huggingface|^lmstudio|^ollama|^llm|[-_]llm|rocm|^stable-diffusion)'
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
    $result = [pscustomobject]@{Bytes=[long]0;Files=[long]0;Directories=[long]0;Errors=[long]0;SkippedLinks=[long]0}
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count) {
        $dir = $stack.Pop()
        $scanErrors = @()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue -ErrorVariable scanErrors)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $result.SkippedLinks++; continue }
            if ($item.PSIsContainer) { $stack.Push($item.FullName) }
            else { $result.Bytes += $item.Length; $result.Files++ }
        }
        $result.Errors += $scanErrors.Count; $result.Directories++
    }
    return $result
}

$homeDir = $env:USERPROFILE
if (-not $homeDir) { $homeDir = [Environment]::GetFolderPath('UserProfile') }
$cache = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Base $homeDir '.cache' }
$hf = if ($env:HF_HOME) { $env:HF_HOME } else { Join-Base $cache 'huggingface' }
$localData=$env:LOCALAPPDATA; $roaming=$env:APPDATA
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
        if ($native) { $path=[AiDiskAuditPortable.Scanner]::Canonical($target.Path) }
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
$fileCount=[long]0; $dirCount=[long]0; $skipped=[long]0
foreach ($target in $selected) {
    if ($ListRoots) { $lines.Add("ROOT`t$($target.Category)`t$($target.Path)"); continue }
    if ($native) { $measurement=[AiDiskAuditPortable.Scanner]::Measure($target.Path) }
    else { $measurement=Measure-Provider $target.Path }
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
