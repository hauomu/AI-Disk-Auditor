<#
AI Disk Auditor v1.0 - Windows

Read-only scanner for local AI/model/cache folders.

Safety:
- Does not delete files
- Does not move files
- Does not change registry
- Does not change PATH
- Does not stop services
- Does not unload models
- Skips inaccessible folders safely

Usage:
  powershell -ExecutionPolicy Bypass -File .\ai-disk-audit.ps1
  powershell -ExecutionPolicy Bypass -File .\ai-disk-audit.ps1 -Report
  powershell -ExecutionPolicy Bypass -File .\ai-disk-audit.ps1 -Comprehensive
  powershell -ExecutionPolicy Bypass -File .\ai-disk-audit.ps1 -Comprehensive -Report
#>

param(
    [switch]$Comprehensive,
    [switch]$Report
)

$ErrorActionPreference = "Continue"
$StartTime = Get-Date

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Get-FolderSizeGB {
    param([string]$Path)

    if (!(Test-Path $Path)) { return $null }

    try {
        $sum = Get-ChildItem $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum

        if ($sum.Sum) { return [math]::Round($sum.Sum / 1GB, 2) }
        return 0
    }
    catch {
        Write-Host "Warning: Could not scan $Path" -ForegroundColor Yellow
        return $null
    }
}

Write-Host ""
Write-Host "AI Disk Auditor v1.0 - Windows" -ForegroundColor Cyan
Write-Host "Read-only audit. This script does not delete, move, or modify files." -ForegroundColor Green
Write-Host "If a folder cannot be scanned, it will be skipped safely." -ForegroundColor Green
Write-Host "Press Ctrl+C at any time to cancel safely." -ForegroundColor Yellow

if ($Comprehensive) {
    Write-Host "Mode: Comprehensive scan. This may take a while." -ForegroundColor Yellow
} else {
    Write-Host "Mode: Quick scan. Use -Comprehensive for deeper scanning." -ForegroundColor Green
}

$Jokes = @(
    "Microsoft archaeology mode: because deprecated things deserve a retirement plan.",
    "Scanning for AI leftovers. Some may be deprecated. Some may be Microsoft.",
    "If this takes too long, remember: somewhere, a wizard is redirecting Documents to OneDrive.",
    "Comprehensive scan enabled: consulting WindowsApps, AppData, ProgramData, and other mythical realms.",
    "Warning: this script may discover three SDKs, two runtimes, and one deprecated dream."
)

Write-Host ""
Write-Host ($Jokes | Get-Random) -ForegroundColor DarkGray

if ($Report) {
    $ReportDir = Join-Path $env:USERPROFILE "AI-Disk-Audit-Reports"
    New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
    $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $ReportPath = Join-Path $ReportDir "ai-disk-audit_$Timestamp.txt"
    Start-Transcript -Path $ReportPath -Force | Out-Null
}

$QuickTargets = @(
    "$env:USERPROFILE\.ollama",
    "$env:USERPROFILE\.lmstudio",
    "$env:USERPROFILE\.continue",
    "$env:USERPROFILE\.cache\huggingface",
    "$env:USERPROFILE\.aitk",
    "$env:LOCALAPPDATA\Microsoft\FoundryLocal",
    "$env:LOCALAPPDATA\Programs\Ollama",
    "$env:LOCALAPPDATA\LM Studio",
    "$env:LOCALAPPDATA\NVIDIA",
    "$env:LOCALAPPDATA\AMD",
    "$env:LOCALAPPDATA\Intel",
    "$env:LOCALAPPDATA\Qualcomm",
    "$env:LOCALAPPDATA\puccinialin",
    "C:\AI",
    "C:\Models"
)

$ComprehensiveTargets = $QuickTargets + @(
    "$env:LOCALAPPDATA\Temp",
    "$env:TEMP",
    "$env:USERPROFILE\.cache",
    "$env:USERPROFILE\.cargo",
    "$env:USERPROFILE\.rustup",
    "$env:USERPROFILE\.conda",
    "$env:USERPROFILE\.vscode",
    "$env:USERPROFILE\.docker",
    "$env:APPDATA\Python",
    "$env:LOCALAPPDATA\pip",
    "$env:LOCALAPPDATA\npm-cache",
    "$env:LOCALAPPDATA\huggingface",
    "$env:LOCALAPPDATA\onnxruntime",
    "$env:LOCALAPPDATA\OpenVINO",
    "$env:LOCALAPPDATA\Intel\NPU",
    "$env:LOCALAPPDATA\Intel\OpenVINO",
    "$env:LOCALAPPDATA\AMD\RyzenAI",
    "$env:LOCALAPPDATA\AMD\VitisAI",
    "$env:LOCALAPPDATA\Microsoft\DirectML",
    "$env:LOCALAPPDATA\Microsoft\WindowsAI",
    "C:\ProgramData\NVIDIA Corporation",
    "C:\ProgramData\AMD",
    "C:\ProgramData\Intel",
    "C:\ProgramData\Qualcomm",
    "C:\ProgramData\Microsoft\WindowsAI",
    "C:\Qualcomm",
    "C:\AMD",
    "C:\Intel",
    "C:\Program Files\NVIDIA Corporation",
    "C:\Program Files\AMD",
    "C:\Program Files\Intel",
    "C:\Program Files\Qualcomm",
    "C:\Program Files\Intel\OpenVINO",
    "C:\Program Files\AMD\RyzenAI",
    "C:\Program Files\AMD\ROCm",
    "C:\Program Files\AMD\VitisAI"
)

$Targets = if ($Comprehensive) { $ComprehensiveTargets } else { $QuickTargets }
$Targets = $Targets | Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique

Write-Section "Folder Size Summary"

$Results = foreach ($Target in $Targets) {
    $Size = Get-FolderSizeGB $Target
    if ($null -ne $Size) {
        [PSCustomObject]@{ SizeGB = $Size; Path = $Target }
    }
}

$Results | Sort-Object SizeGB -Descending | Format-Table -AutoSize

Write-Section "Ollama Models"
try {
    if (Get-Command ollama -ErrorAction SilentlyContinue) { ollama list }
    else { Write-Host "Ollama not found or not available." -ForegroundColor Yellow }
}
catch { Write-Host "Ollama check failed safely." -ForegroundColor Yellow }

Write-Section "Foundry Local Cache"
try {
    if (Get-Command foundry -ErrorAction SilentlyContinue) { foundry cache list }
    else { Write-Host "Foundry CLI not found or not available." -ForegroundColor Yellow }
}
catch { Write-Host "Foundry cache check failed safely." -ForegroundColor Yellow }

$Elapsed = (Get-Date) - $StartTime
Write-Host ""
Write-Host "Completed in $([math]::Round($Elapsed.TotalSeconds, 1)) seconds." -ForegroundColor Green

if ($Report) {
    Stop-Transcript | Out-Null
    Write-Host "Report saved to: $ReportPath" -ForegroundColor Green
    notepad $ReportPath
}
