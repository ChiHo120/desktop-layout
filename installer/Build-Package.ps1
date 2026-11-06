# Builds 发布\桌面布局安装包 and a zip. Does not include secrets or project memory.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$package = Join-Path $repo '发布\桌面布局安装包'
$petOut = Join-Path $package 'payload\pet'
$tasksOut = Join-Path $package 'payload\tasks'
if (Test-Path -LiteralPath $package) { Remove-Item -LiteralPath $package -Recurse -Force }
New-Item -ItemType Directory -Force -Path $petOut, $tasksOut | Out-Null

$petFiles = @(
    'pet.ps1', 'start.bat', 'sensors.ps1', 'cursor-quota.ps1', 'token-quota.ps1',
    'quota-settings.ps1', 'quota-worker.ps1', 'folder-hub.ps1', 'check-place.ps1', 'README.md'
)
foreach ($name in $petFiles) {
    $source = Join-Path $repo $name
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $petOut $name) }
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Setup.ps1') -Destination (Join-Path $package 'Setup.ps1')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '安装.bat') -Destination (Join-Path $package '安装.bat')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '启动桌面布局.ps1') -Destination (Join-Path $tasksOut '启动桌面布局.ps1')

$taskRoot = 'D:\Tree_tasks'
$taskScripts = @(
    'dock-glass.ps1', 'dock-place.ps1', 'dock-workarea.ps1', 'qq-nowplaying.ps1',
    'codex-tasks.ps1', 'redesign-docks.ps1', 'start-layout.ps1', 'setup-icons.ps1',
    'finalize-layout.ps1', 'StartMenuButton.cs', 'StartMenuButton.exe', 'Codex.lnk',
    'dock-apps.json'
)
foreach ($name in $taskScripts) {
    $source = Join-Path $taskRoot $name
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $tasksOut $name) }
}
$rainmeterOut = Join-Path $tasksOut 'Rainmeter'
New-Item -ItemType Directory -Force -Path $rainmeterOut | Out-Null
& robocopy (Join-Path $taskRoot 'Rainmeter') $rainmeterOut /E /XD Backups /XF *.log *before*.ini /NFL /NDL /NJH /NJS /nc /ns /np
if ($LASTEXITCODE -ge 8) { throw '复制 Rainmeter 失败。' }

$zip = Join-Path $repo '发布\桌面布局安装包.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $package '*') -DestinationPath $zip
Write-Output $zip
