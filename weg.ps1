# weg: deletes files and folders for good, without asking.
# Processes that lock them are killed first. Only weg itself and the shells it was started from are spared.
# Started by the launchers weg (Git Bash) and weg.cmd (cmd, PowerShell) in ~/.local/bin.
# No param block: PowerShell would otherwise try to bind -n and -- itself.

$ErrorActionPreference = 'Stop'

function Show-Usage {
    Write-Host 'Usage: weg [--dry-run] <path> [<path> ...]'
    Write-Host ''
    Write-Host 'Deletes files and folders for good (no recycle bin, no questions).'
    Write-Host 'Processes that lock them are killed first. Junctions and symlinks inside a folder'
    Write-Host 'are removed as links; their targets stay untouched.'
    Write-Host 'Refuses drive roots, Windows, Program Files, ProgramData and your user folder.'
    Write-Host ''
    Write-Host '  -n, --dry-run   only show what would be killed and deleted'
    Write-Host '  -h, --help      show this help'
    Write-Host '  --              end of options; use it for paths starting with -'
}

$dryRun = $false
$Paths = @()
$options = $true
foreach ($a in $args) {
    if ($options -and $a -eq '--') { $options = $false }
    elseif ($options -and ($a -eq '-n' -or $a -eq '--dry-run')) { $dryRun = $true }
    elseif ($options -and ($a -eq '-h' -or $a -eq '--help')) { Show-Usage; exit 0 }
    elseif ($options -and $a.StartsWith('-')) { [Console]::Error.WriteLine("weg: unknown option: $a (use -- before paths starting with -)"); exit 2 }
    else { $options = $false; $Paths += $a }
}
if (-not $Paths) { Show-Usage; exit 2 }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class WegNative {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool IsWow64Process(IntPtr h, out bool wow);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, byte[] info, int len, out int ret);

    static bool Read(IntPtr h, long addr, byte[] buf) {
        IntPtr read;
        return ReadProcessMemory(h, new IntPtr(addr), buf, buf.Length, out read);
    }

    // Working directory of a 64-bit process, read from its PEB; null if it cannot be read.
    public static string CurrentDirectory(int pid) {
        IntPtr h = OpenProcess(0x0410, false, pid); // PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
        if (h == IntPtr.Zero) return null;
        try {
            bool wow;
            if (!IsWow64Process(h, out wow) || wow) return null;
            byte[] pbi = new byte[48];
            int ret;
            if (NtQueryInformationProcess(h, 0, pbi, pbi.Length, out ret) != 0) return null;
            long peb = BitConverter.ToInt64(pbi, 8);
            byte[] ptr = new byte[8];
            if (!Read(h, peb + 0x20, ptr)) return null;                         // PEB.ProcessParameters
            byte[] us = new byte[16];
            if (!Read(h, BitConverter.ToInt64(ptr, 0) + 0x38, us)) return null; // CurrentDirectory.DosPath
            byte[] s = new byte[BitConverter.ToUInt16(us, 0)];
            if (!Read(h, BitConverter.ToInt64(us, 8), s)) return null;
            return Encoding.Unicode.GetString(s);
        } finally {
            CloseHandle(h);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public uint StartLow; public uint StartHigh; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint session, int flags, StringBuilder key);
    [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint session);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint session, uint nFiles, string[] files, uint nApps, IntPtr apps, uint nServices, string[] services);
    [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint session, out uint needed, ref uint count, [In, Out] RM_PROCESS_INFO[] info, ref uint reasons);

    // Processes that have one of the files open. The Restart Manager needs no administrator rights for this.
    public static List<int> LockingProcesses(List<string> files) {
        var pids = new List<int>();
        for (int start = 0; start < files.Count; start += 1000) {
            string[] chunk = files.GetRange(start, Math.Min(1000, files.Count - start)).ToArray();
            uint session;
            if (RmStartSession(out session, 0, new StringBuilder(33)) != 0) continue;
            try {
                if (RmRegisterResources(session, (uint)chunk.Length, chunk, 0, IntPtr.Zero, 0, null) != 0) continue;
                uint needed, count = 0, reasons = 0;
                if (RmGetList(session, out needed, ref count, null, ref reasons) != 234 || needed == 0) continue; // 234: ERROR_MORE_DATA
                var info = new RM_PROCESS_INFO[needed];
                count = needed;
                if (RmGetList(session, out needed, ref count, info, ref reasons) != 0) continue;
                for (int i = 0; i < count; i++)
                    if (!pids.Contains(info[i].Process.dwProcessId)) pids.Add(info[i].Process.dwProcessId);
            } finally {
                RmEndSession(session);
            }
        }
        return pids;
    }

    // Files below root (at most max), without following junctions and symlinks.
    public static List<string> Files(string root, int max) {
        var result = new List<string>();
        var dirs = new Stack<string>();
        dirs.Push(root);
        while (dirs.Count > 0 && result.Count < max) {
            string dir = dirs.Pop();
            try {
                foreach (string f in Directory.EnumerateFiles(dir)) {
                    result.Add(f);
                    if (result.Count >= max) break;
                }
                foreach (string d in Directory.EnumerateDirectories(dir))
                    if ((File.GetAttributes(d) & FileAttributes.ReparsePoint) == 0) dirs.Push(d);
            } catch (Exception) {
                // Skip unreadable folders: this only looks for locks.
            }
        }
        return result;
    }
}
'@

function Test-Inside([string] $path, [string] $root) {
    if (-not $path) { return $false }
    $p = $path.TrimEnd('\')
    return ($p -ieq $root) -or $p.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)
}

# Folders weg never deletes, not even as part of a parent folder.
$protected = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE) |
    Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

function Get-Refusal([string] $full) {
    if ([IO.Path]::GetPathRoot($full).TrimEnd('\') -ieq $full.TrimEnd('\')) { return 'is a drive root' }
    foreach ($p in $protected) {
        if (Test-Inside $p $full) { return "would delete $p" }
    }
    return $null
}

# Deletes with rd or del on a \\?\ path: they do not follow junctions and handle long paths.
# cmd gets the path through an environment variable, so that % and & in it do no harm.
function Remove-Target([string] $full) {
    $env:WEG_TARGET = if ($full.StartsWith('\\')) { '\\?\UNC\' + $full.Substring(2) } else { '\\?\' + $full }
    $ErrorActionPreference = 'Continue'
    if ([IO.Directory]::Exists($full)) {
        $out = & cmd.exe /d /c 'rd /s /q "%WEG_TARGET%"' 2>&1
    } else {
        $out = & cmd.exe /d /c 'del /f /q /a "%WEG_TARGET%"' 2>&1
    }
    Remove-Item Env:WEG_TARGET
    return ($out | ForEach-Object { "$_" }) -join "`n"
}

function Test-Gone([string] $full) {
    return -not ([IO.Directory]::Exists($full) -or [IO.File]::Exists($full))
}

# Processes that lock $full: those with their working directory inside it and those with a file in it open.
# Own: weg itself and the shells it was started from; they are reported, not killed.
function Find-Lockers([string] $full) {
    $all = @{}
    Get-CimInstance Win32_Process | ForEach-Object { $all[[int]$_.ProcessId] = $_ }

    $own = @{}
    $id = $PID
    for ($i = 0; $i -lt 64 -and $all.ContainsKey($id) -and -not $own.ContainsKey($id); $i++) {
        $own[$id] = $true
        $id = [int]$all[$id].ParentProcessId
    }

    $pids = New-Object 'System.Collections.Generic.List[int]'
    foreach ($procId in $all.Keys) {
        if (Test-Inside ([WegNative]::CurrentDirectory($procId)) $full) { $pids.Add($procId) }
    }
    $files = New-Object 'System.Collections.Generic.List[string]'
    if ([IO.Directory]::Exists($full)) { $files.AddRange([WegNative]::Files($full, 20000)) } else { $files.Add($full) }
    foreach ($procId in [WegNative]::LockingProcesses($files)) {
        if (-not $pids.Contains($procId)) { $pids.Add($procId) }
    }

    foreach ($procId in $pids) {
        [pscustomobject]@{
            Id   = $procId
            Name = if ($all.ContainsKey($procId)) { $all[$procId].Name } else { '?' }
            Own  = $own.ContainsKey($procId)
        }
    }
}

$failed = 0
$base = if ($env:WEG_CWD) { $env:WEG_CWD } else { (Get-Location).ProviderPath }

# Resolve the targets first, then leave the working directory, so that weg does not lock a target itself.
$targets = foreach ($p in $Paths) {
    try {
        $full = [IO.Path]::GetFullPath([IO.Path]::Combine($base, $p))
    } catch {
        # For example when cmd in weg.cmd has already replaced a %VARIABLE% in the path.
        [Console]::Error.WriteLine("weg: invalid path: $p")
        $failed++
        continue
    }
    if ([IO.Path]::GetPathRoot($full) -ine $full) { $full = $full.TrimEnd('\') }
    $full
}
Set-Location $env:SystemRoot
[Environment]::CurrentDirectory = $env:SystemRoot

foreach ($full in $targets) {
    $refusal = Get-Refusal $full
    if ($refusal) {
        [Console]::Error.WriteLine("weg: refusing ${full}: $refusal")
        $failed++
        continue
    }
    if (Test-Gone $full) {
        [Console]::Error.WriteLine("weg: not found: $full")
        $failed++
        continue
    }

    if ($dryRun) {
        foreach ($l in Find-Lockers $full) {
            if ($l.Own) { Write-Host "would spare $($l.Name) (PID $($l.Id)): it is the shell weg was started from" }
            else { Write-Host "would kill $($l.Name) (PID $($l.Id))" }
        }
        Write-Host "would remove $full"
        continue
    }

    $out = Remove-Target $full
    if (Test-Gone $full) {
        Write-Host "removed $full"
        continue
    }

    $killed = @()
    foreach ($l in Find-Lockers $full) {
        if ($l.Own) {
            [Console]::Error.WriteLine("weg: not killing $($l.Name) (PID $($l.Id)): it is the shell weg was started from. Leave $full first (cd ..).")
            continue
        }
        try {
            Stop-Process -Id $l.Id -Force -ErrorAction Stop
            Write-Host "killed $($l.Name) (PID $($l.Id))"
            $killed += $l.Id
        } catch {
            [Console]::Error.WriteLine("weg: could not kill $($l.Name) (PID $($l.Id)): $($_.Exception.Message)")
        }
    }
    foreach ($procId in $killed) {
        try { Wait-Process -Id $procId -Timeout 5 -ErrorAction SilentlyContinue } catch { }
    }

    # Windows sometimes releases files only a moment after the process has ended.
    for ($i = 0; $i -lt 10 -and -not (Test-Gone $full); $i++) {
        $out = Remove-Target $full
        if (-not (Test-Gone $full)) { Start-Sleep -Milliseconds 300 }
    }

    if (Test-Gone $full) {
        Write-Host "removed $full"
    } else {
        [Console]::Error.WriteLine("weg: could not remove ${full}")
        if ($out) { [Console]::Error.WriteLine($out) }
        $failed++
    }
}

exit [int]($failed -gt 0)
