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
    Internal function to run provided sql statement. If for some reason it cannot be executed - it returns error as [System.String]
#>

<#
    Function to provide list of filesystems
#>
function list_filesystems() {

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($Drive in (Get-WmiObject -ComputerName $Hostname -Class Win32_Volume | Where-Object { $_.DriveType -eq 3})) {
        $list.Add(@{'{#FILESYSTEM}' = $Drive.Name})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)    
}

<#
    Function to provide data for filesystems
#>
function get_fs_state() {

    $dict = @{}

    foreach ($Drive in (Get-WmiObject -ComputerName $Hostname -Class Win32_Volume | Where-Object { $_.DriveType -eq 3})) {
        $usedSpacePct = [math]::round(($Drive.Capacity - $Drive.FreeSpace)/$Drive.Capacity*100, 4)

        $dict.Add($Drive.Name, @{'total'= $Drive.Capacity; used_pct = $usedSpacePct; used_bytes = $Drive.Capacity - $Drive.FreeSpace; free_bytes = $Drive.FreeSpace})
    }

    return ($dict | ConvertTo-Json -Compress)
}

# execute required check
&$CheckType
