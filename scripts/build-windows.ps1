# Builds Konspekt for Windows into .build\Konspekt-windows and .build\Konspekt-windows.zip:
# konspekt.exe, KonspektTray.exe, the icon and the Swift runtime DLLs they import.
Set-Location (Join-Path $PSScriptRoot '..')

# Native stderr (compiler warnings) is not an error; the exit code is checked instead.
swift build -c release 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$ErrorActionPreference = 'Stop'

$bin = '.build\out\Products\Release-windows-x86_64'
if (-not (Test-Path $bin)) { $bin = (swift build -c release --show-bin-path).Trim() }
$out = '.build\Konspekt-windows'
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force $out | Out-Null

Copy-Item "$bin\konspekt.exe", "$bin\KonspektTray.exe" $out
Copy-Item 'Resources\Konspekt.ico' $out

# Copy runtime DLLs found next to swiftCore.dll, following imports transitively.
$runtime = Split-Path ((where.exe swiftCore.dll) | Select-Object -First 1)
$objdump = (Get-Command llvm-objdump.exe).Source
$queue = [System.Collections.Generic.Queue[string]]::new()
$seen = @{}
Get-ChildItem "$out\*.exe" | ForEach-Object { $queue.Enqueue($_.FullName) }
while ($queue.Count -gt 0) {
    $file = $queue.Dequeue()
    foreach ($line in (& $objdump -p $file)) {
        if ($line -notmatch 'DLL Name:\s*(\S+)') { continue }
        $dll = $Matches[1]
        $src = Join-Path $runtime $dll
        if ($seen.ContainsKey($dll.ToLower()) -or -not (Test-Path $src)) { continue }
        $seen[$dll.ToLower()] = $true
        Copy-Item $src $out
        $queue.Enqueue((Join-Path $out $dll))
    }
}

$zip = '.build\Konspekt-windows.zip'
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path "$out\*" -DestinationPath $zip
Write-Host "Built $out ($($seen.Count) runtime DLLs) and $zip"
