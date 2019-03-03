﻿#!/bin/pwsh

<#
.SYNOPSIS
    Monitoring script for MySQL/MariaDB RDBMS, intended to be executed by Zabbix Agent

.DESCRIPTION
    Connects to the database using .NET connector embedded
    UserParameter provided in oracle.conf file which can be found in $global:RootPath\zabbix_agentd.d directory

.PARAMETER CheckType
    This parameter provides name of function which is required to be executed

.PARAMETER Hostname
    Hostname or IP adress of the server where required instance is running

.PARAMETER Port
    TCP/IP port, normally 3306

.PARAMETER Username
    Database user

    Create the user and grant the following privilegies
 
    SQL> create user svc_zabbix identified by '<password>';
    # TODO: review privileges
    SQL> grant all on mysql.* to svc_zabbix;

.PARAMETER Password
    Encrypted password for the database user. Encrypted string can be generated with $global:RootPath\bin\pwgen.ps1

.INPUTS
    None

.OUTPUTS
    If there are any errors - log files can be found in $global:RootPath\log

.NOTES
    Version:        1.0
    Author:         Eugene Bobkov
    Creation Date:  04/12/2018

.EXAMPLE
    powershell -NoLogo -NoProfile -NonInteractive -executionPolicy Bypass -File D:\DBA\zbxpwsh\bin\zbxmysql.ps1 -CheckType get_instance_state -Hostname db_server -Port 3306 -Username svc_zabbix -Password sefrwe7soianfknewker79s=
#>

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,       # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,        # Host name
    [Parameter(Mandatory=$true, Position=3)][int]$Port,               # Port number
    [Parameter(Mandatory=$true, Position=4)][string]$Username ,       # User name
    [Parameter(Mandatory=$true, Position=5)][string]$Password         # Password
    )

$global:RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
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
    Add-Type -Path "$global:RootPath\dll\Google.Protobuf.dll"
    Add-Type -Path "$global:RootPath\dll\MySQL.Data.dll"

    if ($Password) {
        $dbPassword = Read-EncryptedString -InputString $Password -Password (Get-Content "$global:RootPath\etc\.pwkey")
    }

    # Create connection string
    $connectionString = "Server = $Hostname; Port = $Port; Database = mysql; User Id = $Username; Password = $dbPassword;"

    # How long scripts attempts to connect to instance
    # default is 15 seconds and it will cause saturation issues for Zabbix agent (too many checks) 
    $connectionString += "Connect Timeout = $ConnectTimeout; Default Command Timeout = $CommandTimeout"

    # Create the connection object
    $connection = New-Object MySql.Data.MySqlClient.MySqlConnection("$connectionString")

    # try to open connection
    try {
        [void]$connection.open()
    } 
    catch {
        $error = $_.Exception.Message.Split(':',2)[1].Trim() -Replace ("(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", "xxx.xxx.xxx.xxx")
        Write-Log -Message ('[' + $Hostname + ':' + $CheckType + '] ' + $error)
        return "ERROR: CONNECTION REFUSED: $error"
    }

    # Create command to run using connection
    $command = New-Object MySql.Data.MySqlClient.MySqlCommand
    $command.Connection = $connection
    $command.CommandText = $Query

    $adapter = New-Object MySql.Data.MySqlClient.MySqlDataAdapter($command)
    $dataTable = New-Object System.Data.DataTable

    try {
        [void]$adapter.Fill($dataTable)
        $result = $dataTable
    }
    catch {
        $error = $_.Exception.Message.Split(':',2)[1].Trim() -Replace ("(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", "xxx.xxx.xxx.xxx")
        Write-Log -Message ('[' + $Hostname + ':' + $CheckType + '] ' + $error)
        $result = "ERROR: QUERY FAILED: $error"
    } 
    finally {
        [void]$connection.Close()
    }

    # Comma in front is essential as without it return provides object's value, not object itselt
    return ,$result
}

<#
    Function to check instance status, ONLINE stands for OK, any other results is equalent to FAIL
#>
function get_instance_state() {
    $result = (run_sql -Query 'SHOW DATABASES')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return 'ONLINE'
    }
    # data is not in [System.Data.DataTable] format
    else {
        return $result
    }
}

# execute required check
&$CheckType
