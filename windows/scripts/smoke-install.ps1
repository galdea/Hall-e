param([Parameter(Mandatory)][string]$Installer)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'This installation check only runs on a disposable GitHub-hosted Windows runner; it changes installer registration for Hall-e.'
}
$Installer = (Resolve-Path $Installer).Path
if ([IO.Path]::GetFileName($Installer) -notmatch '^Hall-e-\d+\.\d+\.\d+-windows-x64-setup\.exe$') {
    throw 'Pass a versioned Hall-e Windows x64 installer.'
}
$portable = $Installer -replace '-setup\.exe$', '-portable.zip'
foreach ($package in @($Installer, $portable)) {
    $expected = (Get-Content ($package + '.sha256') -Raw).Trim()
    $actual = (Get-FileHash $package -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + [IO.Path]::GetFileName($package)
    if ($expected -cne $actual) { throw "Package checksum does not match: $package" }
}
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
    if (!$data.success -or !$data.windowLoaded -or !$data.meetingRefreshVerified -or !$data.themeContrastVerified -or !$data.isolatedStorage -or $data.recordedAudio -or $data.cloudRequested) {
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
    # Verify the downloadable ZIP itself, including paths with spaces, rather
    # than launching the unarchived publish directory.
    $portableDir = Join-Path $testRoot 'Portable With Spaces'
    Expand-Archive -LiteralPath $portable -DestinationPath $portableDir
    Test-App (Join-Path $portableDir 'Hall-e.exe') 'portable-startup'
    [IO.File]::WriteAllText((Join-Path $qa 'installer-result.json'), '{"success":true,"installed":true,"updated":true,"uninstalled":true,"portableStarted":true}')
    Write-Output 'Install, update, real WPF startup, uninstall, and portable startup passed.'
} finally {
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
