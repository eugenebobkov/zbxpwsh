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
    try {
        Add-Type -Path "C:\Program Files (x86)\MySQL\MySQL Connector Net 8.0.15\Assemblies\v4.5.2\MySQL.Data.dll"
    }
    catch {
        $_.Exception.Message
    }

    #If ($Password) {
    #    $DBPassword = Read-EncryptedString -InputString $Password -Password (Get-Content "$global:RootPath\etc\.pwkey")
    #}

    # Create connection string
    $connectionString = "Server = $Hostname; Port = $Port; Database = mysql; User Id = $Username; Password = $DBPassword;"

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
        [void]$oracleAdapter.Fill($dataTable)
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
    $result = (run_sql -Query 'SHOW DATABASES;')

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
