#!/bin/pwsh

<#
    Created: 16/11/2018

    Parameters to modify in zabbix agent configuration file:
    # it will allow \ symbol to be used as part of InstanceName variable
    UnsafeUserParameters=1 
    
    UserParameter provided as part of oracle.conf file which has to be places in zabbix_agentd.d directory

    Create user for monitoring 
#>

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,        # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,         # Host name
    [Parameter(Mandatory=$true, Position=3)][int]$Port = 50000,        # Port number if required
    [Parameter(Mandatory=$true, Position=4)][string]$Username = '',    # User name
    [Parameter(Mandatory=$true, Position=5)][string]$Password = '',    # Password
    [Parameter(Mandatory=$true, Position=6)][string]$Database = ''     # Database name
    )

<#
   OS statistics:
      v$ostat
#>

function run_sql() {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)][string]$Query,
        [Parameter(Mandatory=$false)][int32]$ConnectTimeout = 5,      # Connect timeout, how long to wait for instance to accept connection
        [Parameter(Mandatory=$false)][int32]$CommandTimeout = 10      # Command timeout, how long sql statement will be running, if it runs longer - it will be terminated
    )

    $factory = [System.Data.Common.DbProviderFactories]::GetFactory(“IBM.Data.DB2”)
    $cstrbld = $factory.CreateConnectionStringBuilder()
    $cstrbld.Database = $Database
    # TODO: Domain users
    $cstrbld.UserID = $Username
    $cstrbld.Password = $Password
    $cstrbld.Server = "$Hostname" + ":$Port"

    $cstrbld.Connect_Timeout = $ConnectTimeout

    $db2Connection = $factory.CreateConnection()
    $db2Connection.ConnectionString = $cstrbld.ConnectionString

    # try to open connection
    try {
        [void]$db2Connection.Open()
    } 
    catch {
        write-Host $_
        return 'ERROR: CONNECTION REFUSED'
    }

    $dbcmd = $factory.CreateCommand()
    $dbcmd.Connection = $db2Connection
    $dbcmd.CommandText = $Query
    $dbcmd.CommandType = [System.Data.CommandType]::Text
    $dbcmd.CommandTimeout = $CommandTimeout

    $da = $factory.CreateDataAdapter()
    $da.SelectCommand = $dbcmd

    $dataTable = New-Object System.Data.DataTable
    try {
        [void]$da.Fill($dataTable)
        $result = $dataTable
    }
    catch {
        # TODO: better handling and logging for invalid statements
        # DEBUG: To print error
        Write-Host "$_"
        $result = 'ERROR: QUERY TIMED OUT'
    } 
    finally {
        $db2Connection.Close()
    }

    # Comma in front is essential as without it return provides object's value, not object itselt
    return ,$result
}

<#
Function to check database availability
#>
function get_database_state() {
    
    $result = (run_sql -Query 'SELECT count(*) FROM syscat.tablespaces')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -gt 0) {
        return 'OK'
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }
    else {
        return 'ERROR: UNKNOWN'
    }
}

function get_version() {
    
    $result = (run_sql -Query "SELECT getvariable('SYSIBM.VERSION') FROM sysibm.sysdummy1")

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        $result.Rows[0][0] 
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }    
    else {
        return 'ERROR: UNKNOWN'
    }
}

# execute required check
&$CheckType