<#
.SYNOPSIS
    Common functions

.DESCRIPTION
    Functions used by other scripts

.NOTES
    Version:        1.0
    Author:         Eugene Bobkov
    Creation Date:  xx/10/2018
#>

<#
.SYNOPSYS
    Function to create line on display (in debug mode) and in log file

.PARAMETER Message
    Text which will be printed
#>
function Write-Log {
    param (
        [Parameter(Mandatory=$true)][string]$Message                # Message which has to be writted to log file and output
    )
 
    $MessageTimestamp = (Get-Date -Format 'dd/MM/yyyy HH:mm:ss')

    # get logfile name based on name of script and day of week
    $logFile = "$global:RootPath\log\$global:ScriptName." + (Get-Date -f 'ddd') + '.log'

    # log file retention based on day of week, if it's more than 7 days - file must be recreated
    if (Test-Path -Path $logFile) {
        if ((Get-ChildItem -Path $logFile).LastWriteTime -le (Get-Date).AddDays(-6)) {
            Clear-Content -Path $logFile
       } 
    }
   
    $logLine = '[' + $MessageTimestamp + ']: '+ $Message
    
    if ($env:ZBXDEBUG -gt 0) {
        Write-Host $logLine -foregroundcolor red
    }
        
    $logLine | Add-Content -Path $logFile
}

Export-ModuleMember -Function Write-Log 