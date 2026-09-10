param([ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '0.1.0')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows) { throw 'Package on Windows so the installer and real app can be verified.' }
$root = Split-Path $PSScriptRoot -Parent
$publish = Join-Path $root 'artifacts/publish/win-x64'
$release = Join-Path $root 'artifacts/release'
New-Item -ItemType Directory -Force $publish, $release | Out-Null
dotnet publish (Join-Path $root 'HallE.Windows/HallE.Windows.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -p:Version=$Version -o $publish
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
Copy-Item (Join-Path $root '../LICENSE') (Join-Path $publish 'LICENSE.txt')
Copy-Item (Join-Path $root 'README.md') (Join-Path $publish 'README-Windows.md')
$compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
if (!(Test-Path $compiler)) { throw 'Inno Setup 6 is required to create the installer.' }
& $compiler "/DAppVersion=$Version" "/DPublishDir=$publish" "/DOutputDir=$release" (Join-Path $root 'installer/Hall-e.iss')
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
$zip = Join-Path $release "Hall-e-$Version-windows-x64-portable.zip"
Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $zip -Force
Get-ChildItem $release -File | Where-Object Extension -In '.exe', '.zip' | ForEach-Object {
    $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($_.FullName + '.sha256', "$hash  $($_.Name)`n", [Text.UTF8Encoding]::new($false))
}
Write-Output "Packaged Hall-e $Version for Windows 11 x64 in $release"
