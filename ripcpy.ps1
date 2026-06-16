param(
    [Parameter(Mandatory)][string] $Source,
    [Parameter(Mandatory)][string] $Target,
    [int] $Parallel = 12,    # concurrent robocopy processes (level-1 parallelism)
    [int] $Threads  = 32,   # robocopy /MT per process      (level-2 parallelism)
    [int] $MaxDepth = 8,    # max depth to recurse when breaking up fat directories
    [int] $Spread   = 3     # job granularity multiplier; higher = more/smaller jobs
)
$ErrorActionPreference = 'Stop'

$item = Get-Item -LiteralPath $Source

# ---- SINGLE FILE FAST PATH ---------------------------------------------------
if (-not $item.PSIsContainer) {
    $srcDir  = $item.DirectoryName
    $srcName = $item.Name
    $out = robocopy $srcDir $Target $srcName /MT:$Threads /R:1 /W:1
    $code = $LASTEXITCODE
    if ($code -ge 8) { $out | ForEach-Object { Write-Host $_ }; Write-Error "Copy failed."; exit 1 }
    Write-Host "Done."; exit 0
}

# Resolves $Source to its full absolute path
$srcFull = $item.FullName.TrimEnd('\')

function Get-RelDst([string]$path) {
    $rel = $path.Substring($srcFull.Length).TrimStart('\')
    if ($rel) { Join-Path $Target $rel } else { $Target }
}

# ---- 0. LEVEL-BY-LEVEL SCAN --------------------------------------------------
# Walk the tree manually down to $MaxDepth, building per-directory metadata.
# At MaxDepth (or at leaf dirs before it), stop recursing and bulk-count the
# subtree with a single .NET enumeration — no per-file PowerShell overhead.
$recCount    = @{}   # dir -> recursive file count (dir + all descendants)
$directCount = @{}   # dir -> files directly in dir (non-recursive)
$children    = @{}   # dir -> set of immediate child dirs that contain files

$bulkEnumOpts = [System.IO.EnumerationOptions]@{ RecurseSubdirectories = $true; IgnoreInaccessible = $true }

function Scan-Dir([string]$dir, [int]$depth) {
    try {
        $subdirs = [System.IO.Directory]::GetDirectories($dir)
        $files   = [System.IO.Directory]::GetFiles($dir).Length
    } catch [System.UnauthorizedAccessException] { return }
    $directCount[$dir] = $files
    $total = $files

    if ($depth -ge $MaxDepth -or $subdirs.Length -eq 0) {
        # At or beyond MaxDepth: bulk-count each subdirectory without further recursion.
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
        # Above MaxDepth: recurse into each subdirectory.
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
Scan-Dir $srcFull 0

# ---- 1. RECURSIVE SPLIT -----------------------------------------------------
# Break up any directory whose file-count exceeds the target bucket-share. A
# "subtree" job copies a whole directory (robocopy /E, internally threaded); a
# "files" job copies only the loose files in a split node (no /E).
$total = $recCount[$srcFull] ?? 0
if ($total -eq 0) { Write-Host "Nothing to copy."; exit 0 }
$shareTarget = [math]::Max(1, [math]::Ceiling($total / ($Parallel * $Spread)))

$jobs = [System.Collections.Generic.List[object]]::new()

function Add-Jobs([string]$dir, [int]$depth, [int]$weight) {
    $subdirs = if ($children.ContainsKey($dir)) { @($children[$dir]) } else { @() }

    # Stop descending: small enough, hit max depth, or can't split (leaf dir).
    if ($weight -le $shareTarget -or $depth -ge $MaxDepth -or $subdirs.Count -eq 0) {
        $jobs.Add([pscustomobject]@{ Src = $dir; Dst = (Get-RelDst $dir); Recurse = $true; Weight = $weight })
        return
    }

    # Loose files directly in this split node get their own non-recursive job.
    $direct = $directCount[$dir] ?? 0
    if ($direct -gt 0) {
        $jobs.Add([pscustomobject]@{ Src = $dir; Dst = (Get-RelDst $dir); Recurse = $false; Weight = $direct })
    }
    foreach ($sd in $subdirs) {
        Add-Jobs $sd ($depth + 1) ($recCount[$sd] ?? 0)
    }
}
Add-Jobs $srcFull 0 $total

# ---- 2. DISPATCH ------------------------------------------------------------
# Feed jobs (heaviest-first) into a parallel pipeline with ThrottleLimit acting
# as a natural work queue: as each robocopy finishes, the next job starts
# immediately. No static bucket assignment — no workers ever idle while work remains.
Write-Host ("Dispatching {0} job(s), {1} concurrent runners, {2} files total.`n" -f `
    $jobs.Count, $Parallel, $total)

$sw = [System.Diagnostics.Stopwatch]::StartNew()

$results = $jobs | Sort-Object Weight -Descending | ForEach-Object -Parallel {
    $threads = $using:Threads
    $jobSw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($_.Recurse) { $out = robocopy $_.Src $_.Dst /E /MT:$threads /R:1 /W:1 }
    else            { $out = robocopy $_.Src $_.Dst    /MT:$threads /R:1 /W:1 }
    $code = $LASTEXITCODE
    $jobSw.Stop()
    $filesLine = ($out | Where-Object { $_ -match '^\s*Files :\s+\d' } | Select-Object -Last 1)
    $name = Split-Path $_.Dst -Leaf
    $info = if ($filesLine) { $filesLine.Trim() } else { "$($_.Weight) files" }
    $status = if ($code -ge 8) { 'FAIL' } else { 'ok' }
    Write-Host ("  [{0}] {1}  {2}  ({3:N1}s)" -f $status, $name, $info, $jobSw.Elapsed.TotalSeconds)
    [pscustomobject]@{ Dst = $_.Dst; Code = $code; Files = $filesLine; Output = $out }
} -ThrottleLimit $Parallel

# Robocopy exit codes: <8 = success (1=copied, 2=extras, 3=both...); 8=failures, 16=fatal.
foreach ($r in $results) {
    if ($r.Code -ge 8) {
        Write-Host ("`n  FAILED: {0}" -f (Split-Path $r.Dst -Leaf))
        $r.Output | ForEach-Object { Write-Host "    $_" }
    }
}

$worst = ($results | ForEach-Object Code | Measure-Object -Maximum).Maximum
$elapsed = $sw.Elapsed.TotalSeconds
Write-Host ("{0:N1}s elapsed.`n" -f $elapsed)
if     ($worst -band 16) { Write-Error   "FATAL: robocopy could not run."; exit 16 }
elseif ($worst -band 8)  { Write-Warning "Some files FAILED to copy. See per-job output above."; exit 1 }
else                     { Write-Host    "Done."; exit 0 }
