param(
    [Parameter(Mandatory)][string] $Dir
)

Add-Type @'
using System;
using System.Runtime.InteropServices;

public class RestartManager {
    [StructLayout(LayoutKind.Sequential)]
    public struct RM_UNIQUE_PROCESS {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public int TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    public static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll")]
    public static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    public static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
        uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    public static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
        [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);
}
'@

function Get-LockingProcesses([string[]]$Files) {
    $sessionKey = [guid]::NewGuid().ToString()
    $session = [uint32]0
    if ([RestartManager]::RmStartSession([ref]$session, 0, $sessionKey) -ne 0) {
        Write-Warning "RmStartSession failed"; return @()
    }
    try {
        [RestartManager]::RmRegisterResources($session, [uint32]$Files.Count, $Files, 0, $null, 0, $null) | Out-Null
        $needed = [uint32]0; $count = [uint32]0; $reason = [uint32]0
        # First call: get count
        [RestartManager]::RmGetList($session, [ref]$needed, [ref]$count, $null, [ref]$reason) | Out-Null
        if ($needed -eq 0) { return @() }
        # Second call: get actual data
        $infoType = [RestartManager].Assembly.GetType('RestartManager+RM_PROCESS_INFO')
        $procs    = [System.Array]::CreateInstance($infoType, [int]$needed)
        $count    = $needed
        [RestartManager]::RmGetList($session, [ref]$needed, [ref]$count, $procs, [ref]$reason) | Out-Null
        return $procs[0..([int]$count - 1)]
    } finally {
        [RestartManager]::RmEndSession($session) | Out-Null
    }
}

function Invoke-RobocopyMir([string]$Src, [string]$Dst) {
    $lines = robocopy $Src $Dst /MIR /MT:32 /R:1 /W:1
    $lines | ForEach-Object { Write-Host $_ }
    # Robocopy error lines: "ERROR 32 (0x00000020) Deleting File C:\path\file.txt"
    $failed = $lines |
        Where-Object   { $_ -match 'ERROR.*(?:Deleting|Copying)\s+(?:File|Dir)\s+(.+)$' } |
        ForEach-Object { $Matches[1].Trim() }
    return @{ ExitCode = $LASTEXITCODE; Failed = @($failed) }
}

$e = "$env:TEMP\robocopy_empty"
New-Item $e -ItemType Directory -Force | Out-Null

try {
    $result = Invoke-RobocopyMir $e $Dir

    if ($result.ExitCode -band 8) {
        $failed = $result.Failed
        if ($failed.Count -gt 0) {
            Write-Host "`nFound $($failed.Count) locked file(s) — querying Restart Manager..."
            $lockers = Get-LockingProcesses $failed
            $killed  = 0
            foreach ($l in $lockers) {
                $tag = if ($l.bRestartable) { "restartable" } else { "NOT restartable" }
                Write-Warning "Killing '$($l.strAppName)' (PID $($l.Process.dwProcessId)) — $tag"
                Stop-Process -Id $l.Process.dwProcessId -Force -ErrorAction SilentlyContinue
                $killed++
            }
            if ($killed -gt 0) {
                Write-Host "Retrying after killing $killed process(es)..."
                $result = Invoke-RobocopyMir $e $Dir
            }
        }
    }

    if     ($result.ExitCode -band 16) { Write-Error   "FATAL: robocopy could not run." }
    elseif ($result.ExitCode -band 8)  { Write-Warning "Some files still FAILED to delete." }
    else {
        Remove-Item $Dir -Force -ErrorAction SilentlyContinue
        Write-Host "Done."
    }
} finally {
    Remove-Item $e -Force -ErrorAction SilentlyContinue
}

