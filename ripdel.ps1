param(
    [Parameter(Mandatory)][string] $Path,
    [int] $Parallel = 8,    # concurrent robocopy /MIR processes
    [int] $Threads  = 32,   # robocopy /MT per process
    [int] $MaxDepth = 8,    # max depth to recurse when splitting fat directories
    [int] $Spread   = 3     # job granularity multiplier; higher = more/smaller jobs
)
$ErrorActionPreference = 'Stop'

$target = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\')
if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    Write-Error "Target is not a directory: $target"; exit 1
}

# ---- 0. SCAN -----------------------------------------------------------------
# Walk the target tree down to $MaxDepth building per-directory file counts.
# At MaxDepth, bulk-count via .NET enumeration (no per-file PowerShell overhead).
$recCount    = @{}   # dir -> recursive file count
$directCount = @{}   # dir -> files directly in dir
$children    = @{}   # dir -> set of immediate child dirs containing files

$bulkEnumOpts = [System.IO.EnumerationOptions]@{ RecurseSubdirectories = $true; IgnoreInaccessible = $true }

function Scan-Dir([string]$dir, [int]$depth) {
    try {
        $subdirs = [System.IO.Directory]::GetDirectories($dir)
        $files   = [System.IO.Directory]::GetFiles($dir).Length
    } catch [System.UnauthorizedAccessException] { return }
    $directCount[$dir] = $files
    $total = $files

    if ($depth -ge $MaxDepth -or $subdirs.Length -eq 0) {
        foreach ($sd in $subdirs) {
            $count = [System.Linq.Enumerable]::Count(
                [System.IO.Directory]::EnumerateFiles($sd, '*', $bulkEnumOpts))
            $recCount[$sd] = $count
            $total += $count
            if ($count -gt 0) {
                if (-not $children.ContainsKey($dir)) {
                    $children[$dir] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                }
                [void]$children[$dir].Add($sd)
            }
        }
    } else {
        foreach ($sd in $subdirs) {
            Scan-Dir $sd ($depth + 1)
            $total += $recCount[$sd]
            if (($recCount[$sd] ?? 0) -gt 0) {
                if (-not $children.ContainsKey($dir)) {
                    $children[$dir] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                }
                [void]$children[$dir].Add($sd)
            }
        }
    }
    $recCount[$dir] = $total
}
Scan-Dir $target 0

$total = $recCount[$target] ?? 0
if ($total -eq 0) {
    Remove-Item -LiteralPath $target -Recurse -Force
    Write-Host "Removed (empty)."; exit 0
}

# ---- 1. SPLIT ----------------------------------------------------------------
# Break fat directories into subtree jobs. Unlike ripcpy, we only emit subtree
# jobs (no files-only) — stray loose files at split nodes are cleaned up after.
$shareTarget = [math]::Max(1, [math]::Ceiling($total / ($Parallel * $Spread)))
$jobs = [System.Collections.Generic.List[object]]::new()

function Add-Jobs([string]$dir, [int]$depth, [int]$weight) {
    $subdirs = if ($children.ContainsKey($dir)) { @($children[$dir]) } else { @() }

    if ($weight -le $shareTarget -or $depth -ge $MaxDepth -or $subdirs.Count -eq 0) {
        $jobs.Add([pscustomobject]@{ Dir = $dir; Weight = $weight })
        return
    }
    foreach ($sd in $subdirs) {
        Add-Jobs $sd ($depth + 1) ($recCount[$sd] ?? 0)
    }
}
Add-Jobs $target 0 $total

# ---- 2. DISPATCH -------------------------------------------------------------
# Parallel robocopy /MIR from an empty temp dir onto each subtree — multi-threaded
# deletion. Work-queue via ThrottleLimit: as each finishes, next job starts.
$emptyDir = Join-Path ([System.IO.Path]::GetTempPath()) "ripdel-empty-$PID"
[void](New-Item -ItemType Directory -Path $emptyDir -Force)

Write-Host ("Deleting: {0}" -f $target)
Write-Host ("Dispatching {0} job(s), {1} concurrent runners, {2} files total.`n" -f `
    $jobs.Count, $Parallel, $total)

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$results = $jobs | Sort-Object Weight -Descending | ForEach-Object -Parallel {
    $threads  = $using:Threads
    $emptyDir = $using:emptyDir
    $jobSw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = robocopy $emptyDir $_.Dir /MIR /MT:$threads /R:1 /W:1
    $code = $LASTEXITCODE
    $jobSw.Stop()
    $filesLine = ($out | Where-Object { $_ -match '^\s*Files :\s+\d' } | Select-Object -Last 1)
    $name = Split-Path $_.Dir -Leaf
    $info = if ($filesLine) { $filesLine.Trim() } else { "$($_.Weight) files" }
    $status = if ($code -ge 8) { 'FAIL' } else { 'ok' }
    Write-Host ("  [{0}] {1}  {2}  ({3:N1}s)" -f $status, $name, $info, $jobSw.Elapsed.TotalSeconds)
    [pscustomobject]@{ Dir = $_.Dir; Code = $code; Output = $out }
} -ThrottleLimit $Parallel

# ---- 3. CLEANUP --------------------------------------------------------------
# The parallel /MIR pass gutted the tree. Now remove the empty directory shell
# and any stray loose files at split nodes that weren't covered by subtree jobs.
Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $emptyDir -Force -ErrorAction SilentlyContinue

# ---- 4. REPORT ---------------------------------------------------------------
$worst = ($results | ForEach-Object Code | Measure-Object -Maximum).Maximum
$elapsed = $sw.Elapsed.TotalSeconds

# Show full output only for failed jobs
foreach ($r in $results) {
    if ($r.Code -ge 8) {
        Write-Host ("`n  FAILED: {0}" -f (Split-Path $r.Dir -Leaf))
        $r.Output | ForEach-Object { Write-Host "    $_" }
    }
}

Write-Host ("`n{0:N1}s elapsed." -f $elapsed)
if     ($worst -band 16) { Write-Error   "FATAL: robocopy could not run."; exit 16 }
elseif ($worst -band 8)  { Write-Warning "Some files FAILED to delete (likely locked). See output above."; exit 1 }
else                     { Write-Host    "Done."; exit 0 }
