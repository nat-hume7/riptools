param(
    [Parameter(Mandatory)][string] $Source,
    [Parameter(Mandatory)][string] $Target,
    [int] $Parallel   = 4,   # top-level entries copied simultaneously
    [int] $Threads    = 8    # robocopy /MT per job (Parallel * Threads = total I/O)
)

# Split the source into top-level entries and dispatch one robocopy per entry.
# This gives level-1 parallelism even for a single source directory.
$entries = Get-ChildItem -LiteralPath $Source -Force

$exitCodes = $entries | ForEach-Object -Parallel {
    $dst = Join-Path $using:Target $_.Name
    if ($_.PSIsContainer) {
        robocopy $_.FullName $dst /E /MT:$using:Threads /R:1 /W:1
    } else {
        robocopy (Split-Path $_.FullName) $using:Target $_.Name /MT:$using:Threads /R:1 /W:1
    }
    $LASTEXITCODE
} -ThrottleLimit $Parallel

$worst = ($exitCodes | Measure-Object -Maximum).Maximum
if     ($worst -band 16) { Write-Error   "FATAL: robocopy could not run." }
elseif ($worst -band 8)  { Write-Warning "Some files FAILED to copy. Check output above." }
else                     { Write-Host    "Done." }
