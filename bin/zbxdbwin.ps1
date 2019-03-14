#!/bsin/pwsh

<#
.SYNOPSIS
    Monitoring script for Microsoft Windows, intended to be executed by Zabbix Agent

.DESCRIPTION
    Connects to the host using WMI and permissions of domain user running Zabbix agent service
    To get information domain user have to have Local Administrator permissions
    UserParameter provided in dbwin.conf file which can be found in $global:RootPath\zabbix_agentd.d directory

.PARAMETER CheckType
    This parameter provides name of function which is required to be executed

.PARAMETER Hostname
    Hostname or IP adress of the server

.NOTES
    Version:        1.0
    Author:         Eugene Bobkov
    Creation Date:  20/112/2018

.EXAMPLE
    powershell -NoLogo -NoProfile -NonInteractive -executionPolicy Bypass -File D:\DBA\zbxpwsh\bin\dbwin.ps1 -CheckType get_fs_data -Hostname windows_server
#>

param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,      # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname        # Hostname, where to connect
)

$global:RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$global:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Definition

Import-Module -Name "$global:RootPath\lib\Library-Common.psm1"

<#
.SYNOPSIS
    Function to provide list of filesystems on the server
#>
function list_filesystems() {

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($Drive in (Get-WmiObject -ComputerName $Hostname -Class Win32_Volume | Where-Object { $_.DriveType -eq 3})) {
        $list.Add(@{'{#FSNAME}' = $Drive.Name})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)    
}

<#
.SYNOPSIS
    Function to provide information about filesystems
#>
function get_fs_data() {

    $dict = @{}

    foreach ($Drive in (Get-WmiObject -ComputerName $Hostname -Class Win32_Volume | Where-Object { $_.DriveType -eq 3})) {
        if ($Drive.Capacity) {
            $usedSpacePct = [math]::round(($Drive.Capacity - $Drive.FreeSpace)/$Drive.Capacity * 100, 4)

            $dict.Add($Drive.Name, @{'total'= $Drive.Capacity; used_pct = $usedSpacePct; used_bytes = $Drive.Capacity - $Drive.FreeSpace; free_bytes = $Drive.FreeSpace})
        }
        else {
            # Drive information is not available (it can be due to security restrictions)
            $dict.Add($Drive.Name, @{'total'= 0; used_pct = 0; used_bytes = 0; free_bytes = 0})
        }
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
.SYNOPSIS
    Function to provide information about CPU load
#>
function get_cpu_data() {
    # return JSON with required information
    return (@{used_pct = (Get-WmiObject Win32_Processor -ComputerName $Hostname | Measure-Object -property LoadPercentage -Average).Average} | ConvertTo-Json -Compress)
}

<#
.SYNOPSIS
    Function to provide information about CPUs count
#>
function get_cpu_count() {
    # return JSON with required information
    return (@{cpu_count = (Get-WmiObject Win32_Processor -ComputerName $Hostname).NumberOfLogicalProcessors.Count} | ConvertTo-Json -Compress)
}

<#
.SYNOPSIS
    Function to provide information about OS
#>
function get_os_data() {
    # get OS information
    $os = Get-WmiObject Win32_OperatingSystem -ComputerName $Hostname    
    # return JSON with required information
    return (@{boot_time = $os.ConvertToDateTime($os.LastBootUpTime).DateTime; os_version = $os.Caption; service_pack_version = $os.ServicePackMajorVersion} | ConvertTo-Json -Compress)
}

<#
.SYNOPSIS
    Function to provide information about memory utilization
#>
function get_memory_data() {
    # get information about system configuration
    $os = Get-WmiObject win32_operatingsystem -ComputerName $Hostname
    # return JSON with required information
    return (@{ 
                 memory_total_bytes = ($cs.TotalVisibleMemorySize * 1024)
                 memory_used_pct = [math]::round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 100 / $os.TotalVisibleMemorySize, 4)
                 swap_used_pct = [math]::round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) * 100 / $os.TotalVirtualMemorySize, 4)
             } | ConvertTo-Json -Compress)
}

# execute required check
&$CheckType