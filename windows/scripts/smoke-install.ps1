param([Parameter(Mandatory)][string]$Installer)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$qa = Join-Path $root 'artifacts/qa'
New-Item -ItemType Directory -Force $qa | Out-Null
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('Hall-e-install-test-' + [guid]::NewGuid().ToString('N'))
$installDir = Join-Path $testRoot 'App With Spaces'
New-Item -ItemType Directory -Force $installDir | Out-Null

function Invoke-CheckedProcess([string]$File, [string]$Arguments, [int]$Timeout = 120000) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
    if (!$process.WaitForExit($Timeout)) {
        $process.Kill($true)
        throw "Process timed out: $File"
    }
    $process.Refresh()
    if ($process.ExitCode -ne 0) { throw "Process failed with exit code $($process.ExitCode): $File" }
}
function Test-App([string]$Executable, [string]$Name) {
    $result = Join-Path $qa "$Name.json"
    Remove-Item $result -ErrorAction SilentlyContinue
    Invoke-CheckedProcess $Executable "--smoke-test `"$result`""
    if (!(Test-Path $result)) { throw 'The real WPF window did not produce a smoke result.' }
    $data = Get-Content $result -Raw | ConvertFrom-Json
    if (!$data.success -or !$data.windowLoaded -or !$data.meetingRefreshVerified -or !$data.isolatedStorage -or $data.recordedAudio -or $data.cloudRequested) {
        throw "App startup/privacy checks failed: $result"
    }
    if (!(Test-Path ([IO.Path]::ChangeExtension($result, '.png')))) { throw 'Missing real-window screenshot.' }
}

try {
    Invoke-CheckedProcess (Resolve-Path $Installer) "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=`"$installDir`" /LOG=`"$(Join-Path $qa 'install.log')`""
    $exe = Join-Path $installDir 'Hall-e.exe'
    if (!(Test-Path $exe)) { throw 'Installer did not create Hall-e.exe.' }
    if (!(Test-Path (Join-Path $installDir 'coreclr.dll'))) { throw 'Installer is missing the bundled .NET runtime.' }
    Test-App $exe 'installed-startup'
    # Exercise updating an existing installation without downloading any runtime.
    Invoke-CheckedProcess (Resolve-Path $Installer) "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=`"$installDir`""
    Test-App $exe 'updated-startup'
    Invoke-CheckedProcess (Join-Path $installDir 'unins000.exe') '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    if (Test-Path $exe) { throw 'Uninstall left the app executable behind.' }
    Test-App (Join-Path $root 'artifacts/publish/win-x64/Hall-e.exe') 'portable-startup'
    [IO.File]::WriteAllText((Join-Path $qa 'installer-result.json'), '{"success":true,"installed":true,"updated":true,"uninstalled":true,"portableStarted":true}')
    Write-Output 'Install, update, real WPF startup, uninstall, and portable startup passed.'
} finally {
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
