#!/bin/pwsh

<#
    Created: 04/12/2018

    UserParameter provided as part of mysql.conf file which has to be places in zabbix_agentd.d directory

    Create MYSQL user which will be used for monitoring
#>

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,       # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,        # Host name
    [Parameter(Mandatory=$true, Position=3)][int]$Port = 3306,        # Port number
    [Parameter(Mandatory=$true, Position=4)][string]$Username = '',   # User name
    [Parameter(Mandatory=$false, Position=5)][string]$Password = ''   # Password
    )

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$global:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Definition

Import-Module -Name "$global:RootPath\lib\Library-Common.psm1"
Import-Module -Name "$global:RootPath\lib\Library-StringCrypto.psm1"

<# Notes:
#>

function run_sql() {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)][string]$Query,
        [Parameter(Mandatory=$false)][int32]$ConnectTimeout = 5,      # Connect timeout, how long to wait for instance to accept connection
        [Parameter(Mandatory=$false)][int32]$CommandTimeout = 10      # Command timeout, how long sql statement will be running, if it runs longer - it will be terminated
    )

    # Add MySQL .NET connector
    # TODO: Unix implementation, [Environment]::OSVersion.Platform -eq Unix|Win32NT
    Add-Type -Path $RootPath\dll\MySQL.Data.dll

    $dataSource = "(DESCRIPTION =
                       (ADDRESS = (PROTOCOL = TCP)(HOST = $Hostname)(PORT = $Port))
                       (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $Service))
                   )"
 
    If ($Password) {
        $DBPassword = Read-EncryptedString -InputString $Password -Password (Get-Content "$global:RootPath\etc\.pwkey")
    }

    # Create connection string
    $oracleConnectionString = "User Id=$Username; Password=$DBPassword; Data Source=$dataSource;"

    # How long scripts attempts to connect to instance
    # default is 15 seconds and it will cause saturation issues for Zabbix agent (too many checks) 
    $oracleConnectionString += "Connect Timeout = $ConnectTimeout;"

    # Create the connection object
    $oracleConnection = New-Object Oracle.ManagedDataAccess.Client.OracleConnection("$oracleConnectionString")

    # try to open connection
    try {
        [void]$oracleConnection.open()
        } 
    catch {
        $oracleError = $_.Exception.Message.Split(':',2)[1].Trim()
        Write-Log -Message $oracleError
        return "ERROR: CONNECTION REFUSED: $oracleError"
    }

    # Create command to run using connection
    $oracleCommand = New-Object Oracle.ManagedDataAccess.Client.OracleCommand
    $oracleCommand.Connection = $oracleConnection
    $oracleCommand.CommandText = $Query
    $oracleCommand.CommandTimeout = $CommandTimeout

    $oracleAdapter = New-Object Oracle.ManagedDataAccess.Client.OracleDataAdapter($oracleCommand)
    $dataTable = New-Object System.Data.DataTable

    try {
        [void]$oracleAdapter.Fill($dataTable)
        $result = $dataTable
    }
    catch {
        $oracleError = $_.Exception.Message.Split(':',2)[1].Trim()
        Write-Log -Message $oracleError
        $result = "ERROR: QUERY FAILED: $oracleError"
    } 
    finally {
        [void]$oracleConnection.Close()
    }

    # Comma in front is essential as without it return provides object's value, not object itselt
    return ,$result
} 

# execute required check
&$CheckType
