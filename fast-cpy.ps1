param(
    [Parameter(Mandatory)][string] $Source,
    [Parameter(Mandatory)][string] $Target,
    [int] $Parallel = 8,    # buckets copied simultaneously (level-1 parallelism)
    [int] $Threads  = 32,    # robocopy /MT per job          (level-2 parallelism)
    [int] $MaxDepth = 8,    # the maximum depth we will recurse to break up fat directories
    [int] $Spread   = 3     # target jobs-per-bucket; higher = finer LPT balance
)
$ErrorActionPreference = 'Stop'

$srcFull = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\')

function Get-RelDst([string]$path) {
    $rel = $path.Substring($srcFull.Length).TrimStart('\')
    if ($rel) { Join-Path $Target $rel } else { $Target }
}
function Get-FileCount([string]$dir) {
    (Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object).Count
}

# ---- 1. RECURSIVE SPLIT -----------------------------------------------------
# Walk the tree, breaking up any directory whose file-count exceeds the target
# bucket-share. A "subtree" job copies a whole directory (robocopy /E, internally
# threaded). A "files" job copies only the loose files in a split node (no /E).
$total  = Get-FileCount $srcFull
if ($total -eq 0) { Write-Host "Nothing to copy."; exit 0 }
$shareTarget = [math]::Max(1, [math]::Ceiling($total / ($Parallel * $Spread)))

$jobs = [System.Collections.Generic.List[object]]::new()

function Add-Jobs([string]$dir, [int]$depth, [int]$weight) {
    $subdirs = @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)

    # Stop descending: small enough, hit max depth, or can't split (leaf dir).
    if ($weight -le $shareTarget -or $depth -ge $MaxDepth -or $subdirs.Count -eq 0) {
        $jobs.Add([pscustomobject]@{ Src = $dir; Dst = (Get-RelDst $dir); Recurse = $true; Weight = $weight })
        return
    }

    # Loose files directly in this split node get their own non-recursive job.
    $direct = (Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    if ($direct -gt 0) {
        $jobs.Add([pscustomobject]@{ Src = $dir; Dst = (Get-RelDst $dir); Recurse = $false; Weight = $direct })
    }
    foreach ($sd in $subdirs) {
        Add-Jobs $sd.FullName ($depth + 1) (Get-FileCount $sd.FullName)
    }
}
Add-Jobs $srcFull 0 $total

# ---- 2. LPT BUCKET ASSIGNMENT ----------------------------------------------
# Sort jobs heaviest-first; drop each into whichever bucket is currently emptiest.
$buckets = 1..$Parallel | ForEach-Object {
    [pscustomobject]@{ Load = 0; Jobs = [System.Collections.Generic.List[object]]::new() }
}
foreach ($j in ($jobs | Sort-Object Weight -Descending)) {
    $b = $buckets | Sort-Object Load | Select-Object -First 1
    $b.Load += $j.Weight
    $b.Jobs.Add($j)
}

Write-Host ("Planned {0} job(s) across {1} bucket(s) (target ~{2} files/job, {3} files total).`n" -f `
    $jobs.Count, $Parallel, $shareTarget, $total)

# ---- 3. DISPATCH ------------------------------------------------------------
# Each bucket runs its jobs sequentially; buckets run in parallel. We CAPTURE
# robocopy output (Out-Host has no host inside a parallel runspace and would leak
# text into the pipeline) and emit one structured result per job.
$results = $buckets | Where-Object { $_.Jobs.Count -gt 0 } | ForEach-Object -Parallel {
    $threads = $using:Threads
    foreach ($j in $_.Jobs) {
        if ($j.Recurse) { $out = robocopy $j.Src $j.Dst /E /MT:$threads /R:1 /W:1 }
        else            { $out = robocopy $j.Src $j.Dst    /MT:$threads /R:1 /W:1 }
        $code = $LASTEXITCODE
        $filesLine = ($out | Where-Object { $_ -match '^\s*Files :\s+\d' } | Select-Object -Last 1)
        [pscustomobject]@{ Dst = $j.Dst; Code = $code; Files = $filesLine; Output = $out }
    }
} -ThrottleLimit $Parallel

# Robocopy exit codes: <8 = success (1=copied, 2=extras, 3=both...); 8=failures, 16=fatal.
foreach ($r in $results) {
    Write-Host ("[{0}] {1}" -f $r.Code, (Split-Path $r.Dst -Leaf)) -NoNewline
    if ($r.Files) { Write-Host ("  {0}" -f $r.Files.Trim()) } else { Write-Host "" }
    if ($r.Code -ge 8) { $r.Output | ForEach-Object { Write-Host "    $_" } }
}

$worst = ($results | ForEach-Object Code | Measure-Object -Maximum).Maximum
Write-Host ""
if     ($worst -band 16) { Write-Error   "FATAL: robocopy could not run." }
elseif ($worst -band 8)  { Write-Warning "Some files FAILED to copy. See per-job output above." }
else                     { Write-Host    "Done." }
