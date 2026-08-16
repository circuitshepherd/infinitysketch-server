<#
.SYNOPSIS
    Build a self-contained Windows release of infsketch-server.

.DESCRIPTION
    Produces a folder (and a zip of it) that runs on a Windows machine with NO Swift toolchain,
    NO Visual Studio and NO Developer Mode: the release executable plus the Swift redistributable
    runtime DLLs beside it.

    That distribution shape is not a preference, it is the only one available. Swift 6.3.3 does
    ship a static Windows runtime, but only inside `WindowsExperimental.sdk`, and there is no
    working route from SwiftPM to it: `--static-swift-stdlib` against the default SDK is accepted
    and SILENTLY IGNORED (exit 0, no warning, and the binary still imports all 11 Swift DLLs),
    `-Xswiftc -static-stdlib` fails with "unable to load standard library", and pointing SDKROOT at
    the experimental SDK breaks SwiftPM's own manifest compilation. Revisit when swift.org
    publishes a Windows static Swift SDK the way it already does for Linux and WebAssembly.

.PARAMETER Version
    Version string for the package name. Defaults to `git describe --tags --always`.

.PARAMETER OutputDir
    Where the staged folder and zip are written. Defaults to `dist/` in the repository root.

.PARAMETER SkipBuild
    Package whatever is already in the release build directory instead of rebuilding.

.PARAMETER SkipSmokeTest
    Skip the launch verification. Do not use in CI -- see the smoke-test section for why it is the
    only step that can catch a missing DLL.

.EXAMPLE
    .\scripts\package-windows.ps1
    .\scripts\package-windows.ps1 -Version 1.0.0
#>
[CmdletBinding()]
param(
    [string] $Version,
    [string] $OutputDir,
    [switch] $SkipBuild,
    [switch] $SkipSmokeTest
)

$ErrorActionPreference = "Stop"

# Repository root is the parent of scripts/.
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Write-Step([string] $Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Fail([string] $Message) {
    Write-Host ""
    Write-Host "FAILED: $Message" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------------------------

if (-not $Version) {
    $described = git describe --tags --always 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $described) { $described = "dev" }
    $Version = $described
}
$Version = $Version.TrimStart("v")

if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot "dist" }

$packageName = "infsketch-server-$Version-windows-x86_64"
$stageDir    = Join-Path $OutputDir $packageName
$zipPath     = Join-Path $OutputDir "$packageName.zip"

Write-Host "infsketch-server Windows packager"
Write-Host "  version : $Version"
Write-Host "  output  : $OutputDir"

# ---------------------------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------------------------

# SwiftPM force-writes `core.symlinks = true` into EVERY dependency checkout, overriding whatever
# the machine's git is configured with. Two dependencies (swift-nio, swift-async-algorithms)
# contain symlinks, and Windows refuses to create those unprivileged unless Developer Mode is on --
# so without this the checkout fails and nothing builds. Environment config outranks repo config,
# which is what makes this win. Scoped to this process: it does not touch the user's git setup.
$env:GIT_CONFIG_COUNT   = "1"
$env:GIT_CONFIG_KEY_0   = "core.symlinks"
$env:GIT_CONFIG_VALUE_0 = "false"

if (-not $SkipBuild) {
    Write-Step "Building release"
    swift build -c release --product infsketch-server
    if ($LASTEXITCODE -ne 0) { Fail "swift build failed" }
} else {
    Write-Step "Skipping build (-SkipBuild)"
}

# Packaging must not be what changes the lockfile: this script builds, so a resolve can rewrite the
# file underneath it, and a release whose pins moved as a side effect of packaging is a release
# nobody chose. Restore the committed copy and carry on.
#
# Restored from GIT, not from a snapshot taken when this script started, and that distinction is
# the whole point: ANY SwiftPM command re-resolves, so by the time packaging runs the file may
# ALREADY have been rewritten by an earlier `swift build` or `swift test` in the same session -- a
# snapshot-and-restore guard was written first and faithfully put back whatever it had been handed.
#
# NOT a Windows-specific rule, though it was written believing it was (measured 2026-08-16 on
# macOS: a plain `swift build` rewrites the file there identically). What a resolve drops are pins
# for packages that have LEFT the dependency graph -- from a clean clone SwiftPM checks out exactly
# the pins the lockfile now carries, on macOS and Linux alike -- so the drop is correct and this
# restore is only about WHERE a lockfile change is allowed to come from: a deliberate commit, never
# a build. Outside a git checkout there is nothing to compare against and the check is skipped.
Write-Step "Checking Package.resolved"

$resolvedPath = Join-Path $repoRoot "Package.resolved"
git -C $repoRoot rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -eq 0) {
    $dirty = git -C $repoRoot status --porcelain -- Package.resolved
    if ($dirty) {
        git -C $repoRoot checkout -- Package.resolved
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  RESTORED from git - a resolve had rewritten it during this run" -ForegroundColor Yellow
        } else {
            Fail "Package.resolved was rewritten by a resolve and could not be restored from git. Packaging must not change it as a side effect: run ``git checkout -- Package.resolved``, or commit the change deliberately if you meant it."
        }
    } else {
        Write-Host "  unmodified"
    }
} else {
    Write-Host "  not a git checkout - skipped (verify Package.resolved by hand before committing)" -ForegroundColor Yellow
}
if (Test-Path $resolvedPath) {
    $pins = (Get-Content $resolvedPath -Raw | ConvertFrom-Json).pins.Count
    Write-Host "  $pins pins"
}

# `swift build --show-bin-path` rather than a literal `.build\release`: without Developer Mode
# SwiftPM cannot create that convenience symlink, so the only path that always exists is the real
# triple-qualified one (`.build\x86_64-unknown-windows-msvc\release`).
$binPath = (swift build --show-bin-path -c release | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $binPath)) { Fail "could not resolve the release bin path" }

$exePath = Join-Path $binPath "infsketch-server.exe"
if (-not (Test-Path $exePath)) { Fail "infsketch-server.exe not found in $binPath" }

# ---------------------------------------------------------------------------------------------
# Locate the Swift redistributable runtime
# ---------------------------------------------------------------------------------------------
#
# The DLLs must come from the SAME toolchain that produced the exe, so they are derived from the
# active toolchain rather than written down. SDKROOT is set by the Swift installer and has the
# shape <root>\Platforms\<version>\Windows.platform\Developer\SDKs\Windows.sdk; the redistributable
# runtime is the sibling <root>\Runtimes\<version>\usr\bin. Falling back to locating swift.exe
# covers environments that set the toolchain up differently (CI actions, for instance).

Write-Step "Locating the Swift runtime"

$runtimeDir = $null
if ($env:SDKROOT) {
    $sdk = Get-Item $env:SDKROOT.TrimEnd("\") -ErrorAction SilentlyContinue
    if ($sdk) {
        $platformVersionDir = $sdk.Parent.Parent.Parent.Parent   # Platforms\<version>
        if ($platformVersionDir) {
            $candidate = Join-Path $platformVersionDir.Parent.Parent.FullName `
                                   ("Runtimes\{0}\usr\bin" -f $platformVersionDir.Name)
            if (Test-Path $candidate) { $runtimeDir = $candidate }
        }
    }
}

if (-not $runtimeDir) {
    $swiftExe = (Get-Command swift.exe -ErrorAction SilentlyContinue).Source
    if ($swiftExe) {
        # <root>\Toolchains\<version>+Asserts\usr\bin\swift.exe -> <root>, <version>
        $toolchainDir = (Get-Item $swiftExe).Directory.Parent.Parent   # Toolchains\<version>
        $swiftRoot    = $toolchainDir.Parent.Parent
        $version      = $toolchainDir.Name -replace '\+.*$', ''
        $candidate    = Join-Path $swiftRoot.FullName "Runtimes\$version\usr\bin"
        if (Test-Path $candidate) { $runtimeDir = $candidate }
    }
}

if (-not $runtimeDir) {
    Fail "could not locate the Swift redistributable runtime (Runtimes\<version>\usr\bin). Set SDKROOT, or ensure swift.exe is on PATH."
}

$runtimeDlls = Get-ChildItem $runtimeDir -Filter *.dll
if ($runtimeDlls.Count -eq 0) { Fail "no DLLs found in $runtimeDir" }
Write-Host "  $runtimeDir"
Write-Host "  $($runtimeDlls.Count) DLLs"

# ---------------------------------------------------------------------------------------------
# Stage
# ---------------------------------------------------------------------------------------------
#
# EVERY DLL in the redistributable directory is copied, deliberately, rather than the ones the exe
# names in its import table. `dumpbin /dependents` lists 11 Swift DLLs and does NOT list
# _FoundationICU.dll -- but Foundation loads it transitively, and a package built from the import
# table alone dies at startup with a DLL-load failure. Measured: dropping ICU produced a 17 MB zip
# that could not start. The redistributable set is what Swift ships for this purpose; take all of
# it and spend the megabytes.

Write-Step "Staging $packageName"

if (Test-Path $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

Copy-Item $exePath $stageDir
Copy-Item (Join-Path $runtimeDir "*.dll") $stageDir

$readme = @"
infsketch-server $Version (Windows x86_64)
==========================================

The local-network sync server for InfinitySketch. Nothing to install -- the Swift runtime is
included in this folder.

RUNNING IT
----------
Double-click infsketch-server.exe, or from a terminal:

    infsketch-server.exe --docs C:\Users\<you>\infsketch-docs

A console window opens and prints a QR code. Scan it with your iPhone or iPad camera: the app
opens and asks whether to connect to this server. You can also type the address by hand in the
app under Settings.

The web overview is at http://localhost:8080/.

OPTIONS
-------
  --port N        listening port (default 8080)
  --docs DIR      where documents are stored (default: a "docs" folder beside this executable)
  --no-open       do not open a browser at startup

IF IT DOESN'T START
-------------------
The window stays open and tells you why. The usual cause is that another program is already using
port 8080 -- start it on a different one:

    infsketch-server.exe --port 8081

SECURITY -- PLEASE READ
-----------------------
This server has NO PASSWORD and NO ENCRYPTION. Anything that can reach the port can read, change
and delete every document. That is deliberate: it is built for a home or studio network you
trust, like a shared printer. Do not forward it through your router to the internet.

"WINDOWS PROTECTED YOUR PC"
--------------------------
The executable is not code-signed, so SmartScreen may warn the first time. Choose "More info"
then "Run anyway" if you trust the source you downloaded this from.

KEEPING THE FOLDER TOGETHER
---------------------------
infsketch-server.exe needs the .dll files next to it. Moving the .exe out on its own will stop it
starting.
"@

Set-Content -Path (Join-Path $stageDir "README.txt") -Value $readme -Encoding utf8

$staged = Get-ChildItem $stageDir
Write-Host ("  {0} files, {1:N1} MB" -f $staged.Count, (($staged | Measure-Object -Sum Length).Sum / 1MB))

# ---------------------------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------------------------
#
# THIS IS THE ONLY STEP THAT CAN CATCH A MISSING DLL, and it only works because PATH is stripped
# first. On the build machine Swift is installed, so its runtime is found via PATH no matter what
# this package contains -- an incomplete package passes every check and then fails on the machine
# of every single user. Stripping PATH to the system directories reproduces a machine with no
# Swift on it.

if (-not $SkipSmokeTest) {
    Write-Step "Verifying the package runs with no Swift installed"

    $port = 18000
    while ((Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) -and $port -lt 18100) {
        $port++
    }

    $smokeDocs = Join-Path $stageDir "_smoketest-docs"
    $savedPath = $env:PATH
    $savedSdk  = $env:SDKROOT
    $proc = $null
    try {
        $env:PATH = "$env:SystemRoot\system32;$env:SystemRoot;$env:SystemRoot\System32\Wbem"
        $env:SDKROOT = $null
        $proc = Start-Process -FilePath (Join-Path $stageDir "infsketch-server.exe") `
                              -ArgumentList "--port", $port, "--no-open", "--docs", $smokeDocs `
                              -WorkingDirectory $stageDir -PassThru -WindowStyle Hidden
    } finally {
        $env:PATH = $savedPath
        $env:SDKROOT = $savedSdk
    }

    $answered = $false
    for ($i = 1; $i -le 20; $i++) {
        if ($proc.HasExited) { break }
        try {
            $r = Invoke-WebRequest "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 3
            if ($r.StatusCode -eq 200) { $answered = $true; break }
        } catch { Start-Sleep -Milliseconds 1000 }
    }

    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }

    if (-not $answered) {
        Fail "the packaged server did not start with Swift removed from PATH -- the package is incomplete (most likely a missing runtime DLL)"
    }
    Write-Host "  served http://127.0.0.1:$port/ with no Swift on PATH" -ForegroundColor Green

    if (Test-Path $smokeDocs) { Remove-Item -LiteralPath $smokeDocs -Recurse -Force }
}

# ---------------------------------------------------------------------------------------------
# Zip
# ---------------------------------------------------------------------------------------------

Write-Step "Compressing"

if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $stageDir "*") -DestinationPath $zipPath

Write-Host ""
Write-Host "Package ready" -ForegroundColor Green
Write-Host ("  {0}  ({1:N1} MB)" -f $zipPath, ((Get-Item $zipPath).Length / 1MB))
Write-Host ("  {0}" -f $stageDir)
