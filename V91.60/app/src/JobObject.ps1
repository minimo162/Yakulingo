$script:YakuJobObjectHandle = [IntPtr]::Zero

function Initialize-YakuJobObject {
    if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) { return $false }
    try {
        if (-not ('YakuLingo.Native.JobObject' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace YakuLingo.Native {
  [StructLayout(LayoutKind.Sequential)] public struct IO_COUNTERS { public UInt64 ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
  [StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_BASIC_LIMIT_INFORMATION { public Int64 PerProcessUserTimeLimit, PerJobUserTimeLimit; public UInt32 LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public UInt32 ActiveProcessLimit; public UIntPtr Affinity; public UInt32 PriorityClass, SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)] public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION { public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation; public IO_COUNTERS IoInfo; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
  public static class JobObject {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  }
}
"@
        }
        $hJob = [YakuLingo.Native.JobObject]::CreateJobObject([IntPtr]::Zero, $null)
        if ($hJob -eq [IntPtr]::Zero) { throw "CreateJobObject failed. Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
        $info = New-Object YakuLingo.Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        $info.BasicLimitInformation.LimitFlags = 0x2000
        $size = [Runtime.InteropServices.Marshal]::SizeOf($info)
        $ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal($size)
        try {
            [Runtime.InteropServices.Marshal]::StructureToPtr($info, $ptr, $false)
            if (-not [YakuLingo.Native.JobObject]::SetInformationJobObject($hJob, 9, $ptr, [uint32]$size)) { throw "SetInformationJobObject failed. Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
        } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($ptr) }
        if (-not [YakuLingo.Native.JobObject]::AssignProcessToJobObject($hJob, [YakuLingo.Native.JobObject]::GetCurrentProcess())) { throw "AssignProcessToJobObject failed. Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
        $script:YakuJobObjectHandle = $hJob
        return $true
    } catch {
        Write-Warning "Job Objectを設定できませんでした。子プロセス連動終了なしで起動を継続します: $($_.Exception.Message)"
        return $false
    }
}
