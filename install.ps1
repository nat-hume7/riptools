# install.ps1 — One-liner installer for riptools (ripcpy + ripdel)
# Usage: irm https://raw.githubusercontent.com/<you>/random-dev-tools/main/install.ps1 | iex
#
# Installs to ~/.riptools/ and adds to User PATH.
$ErrorActionPreference = 'Stop'

$installDir = Join-Path $HOME '.riptools'
$repo = 'https://raw.githubusercontent.com/nat-hume7/random-dev-tools/main'

Write-Host "Installing riptools to $installDir ..."

# Create install directory
if (-not (Test-Path $installDir)) { [void](New-Item -ItemType Directory -Path $installDir -Force) }

# Download scripts
$files = @('ripcpy.ps1', 'ripdel.ps1')
foreach ($f in $files) {
    Write-Host "  Downloading $f ..."
    Invoke-WebRequest "$repo/$f" -OutFile (Join-Path $installDir $f) -UseBasicParsing
}

# Download handle.exe from Sysinternals Live (used by ripdel for locked-file identification)
$handlePath = Join-Path $installDir 'handle.exe'
if (-not (Test-Path $handlePath)) {
    Write-Host "  Downloading handle.exe (Sysinternals) ..."
    Invoke-WebRequest 'https://live.sysinternals.com/handle64.exe' -OutFile $handlePath -UseBasicParsing
}

# Add to User PATH if not already present
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$installDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$installDir", 'User')
    Write-Host "  Added $installDir to User PATH."
    Write-Host "  (Restart your terminal or run: `$env:Path += `";$installDir`")"
} else {
    Write-Host "  Already on PATH."
}

# Accept handle.exe EULA silently on first run
& (Join-Path $installDir 'handle.exe') -accepteula >$null 2>&1

Write-Host "`nDone! Commands available after PATH reload:"
Write-Host "  ripcpy <source> <target>    # ripper-fast parallel copy"
Write-Host "  ripdel <path> [-Force]      # ripper-fast parallel delete"
