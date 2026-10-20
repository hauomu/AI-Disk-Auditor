param([string]$Workspace,[string]$Auditor)
$ErrorActionPreference='Stop'
$base=Join-Path $Workspace ('windows-enumerator-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($base) | Out-Null
$env:USERPROFILE=Join-Path $base 'profile'
$env:LOCALAPPDATA=Join-Path $base 'local'
$env:APPDATA=Join-Path $base 'roaming'
$env:TEMP=Join-Path $base 'temp'; $env:TMP=$env:TEMP
foreach($path in @($env:USERPROFILE,$env:LOCALAPPDATA,$env:APPDATA,$env:TEMP)){[IO.Directory]::CreateDirectory($path)|Out-Null}
foreach($name in @('HF_HOME','HF_HUB_CACHE','HF_XET_CACHE','HF_ASSETS_CACHE','HF_DATASETS_CACHE','UV_CACHE_DIR','UV_PYTHON_INSTALL_DIR','UV_TOOL_DIR','OLLAMA_MODELS','AI_AUDIT_MODEL_ROOT','AI_AUDIT_STRATA_ROOT')){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
$tree=Join-Path $base 'synthetic-cache'
for($dir=0;$dir -lt 100;$dir++){
  $path=Join-Path $tree ('shard-'+$dir)
  [IO.Directory]::CreateDirectory($path)|Out-Null
  for($file=0;$file -lt 100;$file++){[IO.File]::WriteAllBytes((Join-Path $path ('blob-'+$file)),[byte[]](1,2,3,4))}
}
& ([scriptblock]::Create([IO.File]::ReadAllText($Auditor))) -HomeOnly -Root $tree -ListRoots | Out-Null
[AiDiskAuditInventoryV2.Scanner]::Measure($tree) | Out-Null
Get-ChildItem -LiteralPath $tree -Recurse -Force -File | Measure-Object Length -Sum | Out-Null
$old=@();$new=@();$counts=@()
for($i=0;$i -lt 3;$i++){
  $watch=[Diagnostics.Stopwatch]::StartNew()
  $legacy=Get-ChildItem -LiteralPath $tree -Recurse -Force -File | Measure-Object Length -Sum
  $watch.Stop();$old+=$watch.Elapsed.TotalMilliseconds
  $watch.Restart();$current=[AiDiskAuditInventoryV2.Scanner]::Measure($tree);$watch.Stop();$new+=$watch.Elapsed.TotalMilliseconds
  if($current.Files -ne $legacy.Count -or $current.Bytes -ne $legacy.Sum){throw 'Enumerator results differ'}
}
[pscustomobject]@{Files=$current.Files;Directories=$current.Directories;Bytes=$current.Bytes;LegacyMedianMs=($old|Sort-Object)[1];NativeMedianMs=($new|Sort-Object)[1];RetainedFixture=$base}|ConvertTo-Json
