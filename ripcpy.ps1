param(
    [Parameter(Mandatory)][string] $Source,
    [Parameter(Mandatory)][string] $Target,
    [int] $Parallel = 8,
    [int] $Threads  = 32,
    [int] $MaxDepth = 8,
    [int] $Spread   = 3
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\RipEngine.ps1"

$srcFull = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\')

$result = Invoke-RipEngine -ScanRoot $srcFull -Mode Copy -CopyTarget $Target `
    -Parallel $Parallel -Threads $Threads -MaxDepth $MaxDepth -Spread $Spread

if ($result.Total -eq 0) { Write-Host "Nothing to copy."; exit 0 }
if     ($result.Worst -band 16) { Write-Error   "FATAL: robocopy could not run."; exit 16 }
elseif ($result.Worst -band 8)  { Write-Warning "Some files FAILED to copy. See output above."; exit 1 }
else                            { Write-Host    "Done."; exit 0 }
