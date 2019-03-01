#!/bin/pwsh

<#
    Created: 10/2018

    UserParameter provided as part of pgsql.conf file which has to be places in zabbix_agentd.d directory

    Create Postgres user which will be used for monitoring

    alter role zabbixmon with login;

#>

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,       # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,        # Host name
    [Parameter(Mandatory=$true, Position=3)][int]$Port = 5432,        # Port number
    [Parameter(Mandatory=$true, Position=4)][string]$Username = '',   # User name
    [Parameter(Mandatory=$true, Position=5)][string]$Password = ''    # Password, not required if .pgpass file populated
)

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$global:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Definition

Import-Module -Name "$global:RootPath\lib\Library-Common.psm1"
Import-Module -Name "$global:RootPath\lib\Library-StringCrypto.psm1"

<# Notes:
    Checkpint interval
      pg_stat_bgwriter
      pg_stat_replication - function with security definer has to be created to view full information about replication
#>

function run_sql() {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)][string]$Query,
        [Parameter(Mandatory=$false)][int32]$ConnectTimeout = 5,      # Connect timeout, how long to wait for instance to accept connection
        [Parameter(Mandatory=$false)][int32]$CommandTimeout = 10      # Command timeout, how long sql statement will be running, if it runs longer - it will be terminated
    )
    
    # DEBUG: Error in SQL execution will not terminate whole script and error output will be suppressed
    # $ErrorActionPreference = 'silentlycontinue'

    # Load ADO.NET extention
    # System.Threading.Tasks.Extensions.dll is prerequisite for npgsql
    Add-Type -Path $global:RootPath\dll\System.Runtime.CompilerServices.Unsafe.dll
    Add-Type -Path $global:RootPath\dll\System.ValueTuple.dll
    Add-Type -Path $global:RootPath\dll\System.Threading.Tasks.Extensions.dll
    Add-Type -Path $global:RootPath\dll\Npgsql.dll

    #if ($Password) {
    #    $DBPassword = Read-EncryptedString -InputString $Password -Password (Get-Content "$global:RootPath\etc\.pwkey")
    #}

    # Create connection string
    #$connectionString = "Server = $Hostname; Port = $Port; Database = postgres; User Id = $Username; Password = $DBPassword;"
    $connectionString = "Server = $Hostname; Port = $Port; Database = postgres; User Id = $Username; Password = $Password;"

    # How long scripts attempts to connect to instance
    # default is 15 seconds and it will cause saturation issues for Zabbix agent (too many checks) 
    $connectionString += "Timeout = $ConnectTimeout; CommandTimeout = $CommandTimeout"

    # Create the connection object
    $connection = New-Object Npgsql.NpgsqlConnection("$connectionString")

    # try to open connection
    try {
        [void]$connection.open()
        } 
    catch {
        $error = $_.Exception.Message.Split(':',2)[1].Trim()
        Write-Log -Message $error
        return "ERROR: CONNECTION REFUSED: $error"
    }

    $adapter = New-Object Npgsql.NpgsqlDataAdapter($Query, $connection)
    $dataTable = New-Object System.Data.DataTable

    try {
        [void]$adapter.Fill($dataTable)
        $result = $dataTable
    }
    catch {
        $error = $_.Exception.Message.Split(':',2)[1].Trim()
        Write-Log -Message $error
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
    $result = (run_sql -Query 'SELECT count(*) FROM pg_database')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return 'ONLINE'
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }
    else {
        return "ERROR: UNKNOWN (" + $result.Rows[0][0] + ")"
    }
}

function get_version() {
    $result = (run_sql -Query 'SELECT version()')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return $resul.Rows[0][0]
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $null
    }
    else {
        return "ERROR: UNKNOWN (" + $result.Rows[0][0] + ")"
    }
}

<#
    Function to get instance startup timestamp
#>
function get_startup_time() {
    $result = (run_sql -Query "SELECT pg_postmaster_start_time()")

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return $resul.Rows[0][0]
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }
    else {
        return "ERROR: UNKNOWN (" + $result.Rows[0][0] + ")"
    }
}

function list_databases() {

    $result = (run_sql -Query "SELECT datname FROM pg_database WHERE datistemplate = false")

    if ($result.GetType() -eq [System.String]) {
        # Instance is not available
        return $null
    }

    $idx = 0
    $json = "{ `n`t`"data`": [`n"

    # generate JSON
    foreach ($row in $result) {
        $json += "`t{`"{#DATABASE}`": `"" + $row[0] + "`"}"
        $idx++

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

function get_databases_size() {

    $result = (run_sql -Query "SELECT datname, pg_database_size(datname) FROM pg_database WHERE datistemplate = false")

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.String]) {
        # Instance is not available
        return $null
    }

    $idx = 0
    $json = "{`n"

    # generate JSON
    foreach ($row in $result) {
        $json += "`t`"" + $row[0] + "`":{`"bytes`":`"" + $row[1] + "`"}"
        $idx++

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "}"

    return $json
}

function get_connections_data() {

    $result = (run_sql -Query "SELECT  current_setting('max_connections')::integer   max_connections
                                     , count(pid)::float current_connections  
                                     , trunc(count(pid)::float / current_setting('max_connections')::integer * 100) used_pct
                                 FROM pg_stat_activity")

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return "{`n`"connections`": {`n`t`"max`":" +  $resul.Rows[0][0] + ",`"current`":" +  $resul.Rows[0][1] + ",`"pct`":" +  $resul.Rows[0][2] + "`n}`n}"
    }
    else {
        return $null
    }
}

# execute required check
&$CheckType