# Starts the taskbar, the pet, and the folder window from the paths chosen at install time.
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$configPath = Join-Path $root 'install.json'
if (-not (Test-Path -LiteralPath $configPath)) { throw '找不到 install.json，请重新运行安装程序。' }
$cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

$rainmeter = Join-Path $root 'Rainmeter\Rainmeter.exe'
$ini = Join-Path $root 'Rainmeter\Rainmeter.ini'
if (Test-Path -LiteralPath $rainmeter) {
    $running = Get-Process Rainmeter -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $rainmeter }
    if (-not $running) {
        Start-Process -FilePath $rainmeter -ArgumentList ('"{0}"' -f $ini) -WorkingDirectory (Split-Path $rainmeter)
        Start-Sleep -Milliseconds 900
    }
    & $rainmeter !ActivateConfig 'TreeDock\Top' 'Top.ini'
    & $rainmeter !ActivateConfig 'TreeDock\Left' 'Left.ini'
}

$petBat = Join-Path $cfg.Pet 'start.bat'
if (Test-Path -LiteralPath $petBat) {
    Start-Process -FilePath $petBat -WorkingDirectory $cfg.Pet
}
$hub = Join-Path $cfg.Pet 'folder-hub.ps1'
if (Test-Path -LiteralPath $hub) {
    $existing = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*folder-hub.ps1*' -and $_.CommandLine -notlike '*Get-CimInstance*' })
    if ($existing.Count -eq 0) {
        Start-Process powershell.exe -ArgumentList '-NoProfile','-STA','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$hub -WindowStyle Hidden
    }
}
