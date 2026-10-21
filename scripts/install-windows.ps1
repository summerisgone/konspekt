# Builds Konspekt, installs it into %LOCALAPPDATA%\Programs\Konspekt, enables autostart and starts the tray icon.
#   scripts\install-windows.ps1              install or update
#   scripts\install-windows.ps1 -Uninstall   stop and remove; config and recordings are kept
param([switch]$Uninstall)

$dest = Join-Path $env:LOCALAPPDATA 'Programs\Konspekt'
$configDir = Join-Path $env:APPDATA 'Konspekt'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Stop-Konspekt {
    # The daemon finishes the current call and exits when this event is set.
    try { [System.Threading.EventWaitHandle]::OpenExisting('Local\KonspektDaemonStop').Set() | Out-Null } catch {}
    Get-Process konspekt -ErrorAction SilentlyContinue | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    $left = Get-Process KonspektTray, konspekt -ErrorAction SilentlyContinue
    $left | Stop-Process -Force
    $left | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
}

Set-Location (Join-Path $PSScriptRoot '..')

if ($Uninstall) {
    Stop-Konspekt
    Remove-ItemProperty -Path $runKey -Name 'Konspekt' -ErrorAction SilentlyContinue
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Write-Host 'Uninstalled Konspekt.'
    Write-Host "Kept: $configDir and recordings (default Documents\Konspekt)."
    exit 0
}

& (Join-Path $PSScriptRoot 'build-windows.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$ErrorActionPreference = 'Stop'

Stop-Konspekt
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item '.build\Konspekt-windows\*' $dest

$envFile = Join-Path $configDir '.env'
if (-not (Test-Path $envFile) -and (Test-Path '.env')) {
    New-Item -ItemType Directory -Force $configDir | Out-Null
    Copy-Item '.env' $envFile
}

$tray = Join-Path $dest 'KonspektTray.exe'
Set-ItemProperty -Path $runKey -Name 'Konspekt' -Value "`"$tray`""
Start-Process $tray

Write-Host "Installed $dest and started the tray icon."
if (-not (Test-Path $envFile)) { Write-Host "Fill in the settings: $envFile (opened in Notepad)." }
Write-Host "Logs: $(Join-Path $env:LOCALAPPDATA 'Konspekt\konspekt.log')"
