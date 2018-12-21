#!/bsin/pwsh

<#
    Created: 20/12/2018

    Database related OS monitoring

#>

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,      # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname        # Hostname, where to connect
)

$global:RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$global:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Definition

Import-Module -Name "$global:RootPath\lib\Library-Common.psm1"

<#
    Notes
#> 

<#
    Function to provide list of filesystems
#>
function list_filesystems() {

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($Drive in (Get-WmiObject -ComputerName $Hostname -Class Win32_Volume | Where-Object { $_.DriveType -eq 3})) {
        $list.Add(@{'{#FSNAME}' = $Drive.Name})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)    
}

<#
    Function to provide data for filesystems
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
    Function to provide data for CPU load
#>
function get_cpu_data() {

    return (@{used_pct = (Get-WmiObject win32_processor -ComputerName $Hostname | Measure-Object -property LoadPercentage -Average).Average }| ConvertTo-Json -Compress)

}

<#
    Function to provide data for memory utilization
#>
function get_memory_data() {
  
    $os = Get-WmiObject win32_operatingsystem -ComputerName $Hostname

    return (@{ 
                 memory_used_pct = ("{0:N2}" -f ((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory)*100) / $os.TotalVisibleMemorySize))
                 swap_used_pct = ("{0:N2}" -f ((($os.TotalVirtualMemorySize - $os.FreeVirtualMemory)*100) / $os.TotalVirtualMemorySize))
             } | ConvertTo-Json -Compress)
}

# execute required check
&$CheckType
