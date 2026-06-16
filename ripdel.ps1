param(
    [Parameter(Mandatory)][string] $Path,
    [int] $Parallel = 8,
    [int] $Threads  = 32,
    [int] $MaxDepth = 8,
    [int] $Spread   = 3
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\RipEngine.ps1"

$target = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\')
if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    Write-Error "Target is not a directory: $target"; exit 1
}

# Create temp empty dir for /MIR trick
$emptyDir = Join-Path ([System.IO.Path]::GetTempPath()) "ripdel-empty-$PID"
[void](New-Item -ItemType Directory -Path $emptyDir -Force)

Write-Host ("Deleting: {0}" -f $target)

try {
    $result = Invoke-RipEngine -ScanRoot $target -Mode Delete -DeleteEmptyDir $emptyDir `
        -Parallel $Parallel -Threads $Threads -MaxDepth $MaxDepth -Spread $Spread

    if ($result.Total -eq 0) {
        Remove-Item -LiteralPath $target -Recurse -Force
        Write-Host "Removed (empty)."; exit 0
    }

    # Cleanup: remove the now-gutted directory shell and any stray loose files
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue

    if     ($result.Worst -band 16) { Write-Error   "FATAL: robocopy could not run."; exit 16 }
    elseif ($result.Worst -band 8)  { Write-Warning "Some files FAILED to delete (likely locked). See output above."; exit 1 }
    else                            { Write-Host    "Done."; exit 0 }
} finally {
    Remove-Item -LiteralPath $emptyDir -Force -ErrorAction SilentlyContinue
}
