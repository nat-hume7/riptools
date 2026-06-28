param(
    [Parameter(Mandatory)][string] $Path,
    [switch] $Force   # kill non-critical lockers without prompting
)
$ErrorActionPreference = 'Stop'

# =
# ==
# ===
# ======
# ==========
# ================
# ========================
# ========================================
# =================================================================
# ============================================================================================
# ---- LOCKER DETECTION --------------------------------------------------------
# Three-tier approach:
#   1. PEB CurrentDirectory scan — finds processes cd'd into the target (instant, most common)
#   2. Restart Manager API — finds processes with files open (instant, file-level only)
#   3. handle.exe — finds any remaining open handles (slow fallback, catches everything)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CwdScanner {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("ntdll.dll")]    static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PROCESS_BASIC_INFORMATION info, int size, out int retLen);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr proc, IntPtr baseAddr, byte[] buffer, int size, out int read);

    const int ProcessBasicInformation = 0;
    const int PROCESS_QUERY_INFORMATION = 0x0400;
    const int PROCESS_VM_READ = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_BASIC_INFORMATION {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    public static string GetProcessCwd(int pid) {
        IntPtr hProc = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
        if (hProc == IntPtr.Zero) return null;
        try {
            var pbi = new PROCESS_BASIC_INFORMATION();
            int retLen;
            if (NtQueryInformationProcess(hProc, ProcessBasicInformation, ref pbi, Marshal.SizeOf(pbi), out retLen) != 0)
                return null;
            byte[] buf8 = new byte[8];
            int read;
            if (!ReadProcessMemory(hProc, IntPtr.Add(pbi.PebBaseAddress, 0x20), buf8, 8, out read)) return null;
            IntPtr processParams = (IntPtr)BitConverter.ToInt64(buf8, 0);
            byte[] uniStr = new byte[16];
            if (!ReadProcessMemory(hProc, IntPtr.Add(processParams, 0x38), uniStr, 16, out read)) return null;
            ushort length = BitConverter.ToUInt16(uniStr, 0);
            IntPtr strBuffer = (IntPtr)BitConverter.ToInt64(uniStr, 8);
            if (length == 0 || strBuffer == IntPtr.Zero) return null;
            byte[] strBytes = new byte[length];
            if (!ReadProcessMemory(hProc, strBuffer, strBytes, length, out read)) return null;
            return Encoding.Unicode.GetString(strBytes).TrimEnd('\\');
        } finally { CloseHandle(hProc); }
    }
}
'@ -ErrorAction SilentlyContinue

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public struct RM_UNIQUE_PROCESS {
    public int dwProcessId;
    public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
}
public enum RM_APP_TYPE { RmUnknownApp = 0, RmMainWindow = 1, RmOtherWindow = 2, RmService = 3, RmExplorer = 4, RmConsole = 5, RmCritical = 1000 }
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct RM_PROCESS_INFO {
    public RM_UNIQUE_PROCESS Process;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string strServiceShortName;
    public RM_APP_TYPE ApplicationType;
    public int AppStatus;
    public int TSSessionId;
    [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
}
public static class RestartManager {
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] public static extern int RmStartSession(out int h, int flags, string key);
    [DllImport("rstrtmgr.dll")]                            public static extern int RmEndSession(int h);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] public static extern int RmRegisterResources(int h, int nFiles, string[] files, int nApps, RM_UNIQUE_PROCESS[] apps, int nSvc, string[] svcs);
    [DllImport("rstrtmgr.dll")]                            public static extern int RmGetList(int h, out int needed, ref int count, [In, Out] RM_PROCESS_INFO[] procs, out int reboot);
}
'@ -ErrorAction SilentlyContinue

# How it works:
#  1. Look for handle.exe next to the script (where install.ps1 puts it → ~/.riptools/handle.exe)
#  2. If not there, check PATH for handle.exe or handle64.exe
#  3. If $handleExe is still $null/empty, Tier 3 silently skips — no error, no warning
$handleExe = Join-Path $PSScriptRoot 'handle.exe'
if (-not (Test-Path $handleExe)) {
    $handleExe = (Get-Command handle.exe -ErrorAction SilentlyContinue)?.Source
    if (-not $handleExe) { $handleExe = (Get-Command handle64.exe -ErrorAction SilentlyContinue)?.Source }
}

# They're always used together
# Separated because there's a conditional between them — we only invoke kill+retry if lockers were actually found ($lockers.Count -gt 0).
#     $lockers = Get-Lockers $path          # who?
#     Invoke-KillAndRetry $lockers { ... }  # kill + retry

function Get-Lockers([string]$targetPath, [string[]]$filePaths) {
    $targetNorm = $targetPath.TrimEnd('\')
    $lockers = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $myPid = $PID
    $isCritical = { param($name) $name -in @('System','csrss','smss','wininit','services','lsass') }

    # ---- Tier 1: PEB CurrentDirectory scan (instant) ----
    foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
        if ($proc.Id -eq $myPid -or $proc.Id -le 4) { continue }
        try {
            $cwd = [CwdScanner]::GetProcessCwd($proc.Id)
            if ($cwd -and ($cwd -eq $targetNorm -or $cwd.StartsWith("$targetNorm\", [System.StringComparison]::OrdinalIgnoreCase))) {
                [void]$seen.Add($proc.Id)
                $lockers.Add([pscustomobject]@{ PID = $proc.Id; Name = $proc.ProcessName; Source = 'CWD'; Critical = (& $isCritical $proc.ProcessName) })
            }
        } catch { }
    }

    # ---- Tier 2: Restart Manager (instant, file-level only) ----
    if ($filePaths -and $filePaths.Count -gt 0) {
        for ($batch = 0; $batch -lt $filePaths.Length; $batch += 128) {
            $chunk = $filePaths[$batch..[math]::Min($batch + 127, $filePaths.Length - 1)]
            $handle = 0
            if ([RestartManager]::RmStartSession([ref]$handle, 0, [guid]::NewGuid().ToString()) -ne 0) { continue }
            try {
                if ([RestartManager]::RmRegisterResources($handle, $chunk.Length, $chunk, 0, $null, 0, $null) -ne 0) { continue }
                $needed = 0; $count = 0; $reboot = 0
                [RestartManager]::RmGetList($handle, [ref]$needed, [ref]$count, $null, [ref]$reboot) | Out-Null
                if ($needed -eq 0) { continue }
                $count = $needed
                $procs = [RM_PROCESS_INFO[]]::new($count)
                if ([RestartManager]::RmGetList($handle, [ref]$needed, [ref]$count, $procs, [ref]$reboot) -ne 0) { continue }
                for ($i = 0; $i -lt $count; $i++) {
                    $p = $procs[$i]
                    if ($p.Process.dwProcessId -eq $myPid -or $seen.Contains($p.Process.dwProcessId)) { continue }
                    [void]$seen.Add($p.Process.dwProcessId)
                    $lockers.Add([pscustomobject]@{
                        PID = $p.Process.dwProcessId; Name = $p.strAppName; Source = 'File'
                        Critical = ($p.ApplicationType -eq [RM_APP_TYPE]::RmCritical)
                    })
                }
            } finally { [RestartManager]::RmEndSession($handle) | Out-Null }
        }
    }

    # ---- Tier 3: handle.exe (slow fallback — only if tiers 1+2 found nothing) ----
    if ($handleExe -and $lockers.Count -eq 0) {
        $out = & $handleExe -a -u -accepteula $targetPath 2>&1 | Where-Object { $_ -is [string] }
        foreach ($line in $out) {
            if ($line -match '^(.+?)\s+pid:\s*(\d+)\s+type:\s*(\w+)') {
                $pid = [int]$Matches[2]
                if ($pid -eq $myPid -or $seen.Contains($pid)) { continue }
                [void]$seen.Add($pid)
                $procName = $Matches[1].Trim()
                $lockers.Add([pscustomobject]@{ PID = $pid; Name = $procName; Source = 'Handle'; Critical = (& $isCritical $procName) })
            }
        }
    }

    $lockers
}

# ---- KILL HELPER -------------------------------------------------------------
function Invoke-Kill([object[]]$lockers) {
    $critical = @($lockers | Where-Object Critical)
    $killable = @($lockers | Where-Object { -not $_.Critical })

    Write-Host "`n  Locking processes:"
    foreach ($l in $lockers) {
        $tag = if ($l.Critical) { 'CRITICAL' } elseif ($l.Source) { $l.Source } else { '' }
        Write-Host ("    PID {0,-6} {1,-20} [{2}]" -f $l.PID, $l.Name, $tag)
    }
    if ($critical.Count -gt 0) {
        Write-Host ("`n  {0} CRITICAL process(es) cannot be killed." -f $critical.Count)
    }
    if ($killable.Count -eq 0) { return $false }

    $doKill = $false
    if ($Force) {
        $doKill = $true
        Write-Host "`n  -Force: killing non-critical lockers..."
    } else {
        $answer = Read-Host "`n  Kill $($killable.Count) non-critical process(es) to continue? [y/N]"
        $doKill = $answer -match '^[yY]'
    }
    if (-not $doKill) { return $false }

    foreach ($l in $killable) {
        try {
            Stop-Process -Id $l.PID -Force -ErrorAction Stop
            Write-Host ("    Killed: {0} (PID {1})" -f $l.Name, $l.PID)
        } catch {
            Write-Host ("    Could not kill: {0} (PID {1}) — {2}" -f $l.Name, $l.PID, $_.Exception.Message)
        }
    }
    Start-Sleep -Milliseconds 500
    return $true
}

# ============================================================================================
# MAIN
# ============================================================================================
$item   = Get-Item -LiteralPath $Path
$target = $item.FullName.TrimEnd('\')

Write-Host "Scanning for lockers on: $target"

# Enumerate file paths so Restart Manager (Tier 2) can check file-level locks
if ($item.PSIsContainer) {
    $filePaths = @(Get-ChildItem -LiteralPath $target -Recurse -File -Force -ErrorAction SilentlyContinue |
                   Select-Object -ExpandProperty FullName)
} else {
    $filePaths = @($item.FullName)
}

$lockers = Get-Lockers $target -filePaths $filePaths

if ($lockers.Count -eq 0) {
    Write-Host "No lockers found."
    exit 0
}

Write-Host ("Found {0} locking process(es)." -f $lockers.Count)
$killed = Invoke-Kill $lockers

if ($killed) {
    Write-Host "`nDone. Locks cleared."
    exit 0
} else {
    Write-Host "`nNo locks were cleared."
    exit 1
}