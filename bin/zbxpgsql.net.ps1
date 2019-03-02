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
    [Parameter(Mandatory=$true, Position=5)][string]$Password = ''    # Password
)

$global:RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$global:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Definition

Import-Module -Name "$global:RootPath\lib\Library-Common.psm1"
Import-Module -Name "$global:RootPath\lib\Library-StringCrypto.psm1"

<# Notes:
    Checkpoint interval
      pg_stat_bgwriter
      pg_stat_replication - function with security definer has to be created to view full information about replication
#>

function run_sql() {
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

    if ($Password) {
        $DBPassword = Read-EncryptedString -InputString $Password -Password (Get-Content "$global:RootPath\etc\.pwkey")
    }

    # Create connection string
    $connectionString = "Server = $Hostname; Port = $Port; Database = postgres; User Id = $Username; Password = $DBPassword;"

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
        $error = $_.Exception.Message.Split(':',2)[1].Trim() -Replace ("(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", "xxx.xxx.xxx.xxx")
        Write-Log -Message ('[' + $Hostname + ':' + $CheckType + '] ' + $error)
        return "ERROR: CONNECTION REFUSED: $error"
    }

    $adapter = New-Object Npgsql.NpgsqlDataAdapter($Query, $connection)
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
    $result = (run_sql -Query 'SELECT count(*) FROM pg_database')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return 'ONLINE'
    }
    # data is not in [System.Data.DataTable] format
    else {
        return $result
    }
}

<#
    Function to get software version
#>
function get_version() {
    # get software version
    $result = (run_sql -Query 'SELECT version()')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{version = $result.Rows[0][0]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Function to get instance startup timestamp
#>
function get_startup_time() {
    # get startup time
    $result = (run_sql -Query "SELECT to_char(pg_postmaster_start_time(),'DD/MM/YYYY HH24:MI:SS')")

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{startup_time = $result.Rows[0][0]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

function list_databases() {
    # get list of databases
    $result = @(run_sql -Query 'SELECT datname 
                                  FROM pg_database 
                                 WHERE datistemplate = false')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # instance is not available
        return $result
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
        $list.Add(@{'{#DATABASE}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)
}


<#
    Get size of all databases
#>
function get_databases_size() {
    # get size of all databases
    $result = @(run_sql -Query "SELECT datname
                                     , pg_database_size(datname) 
                                  FROM pg_database 
                                 WHERE datistemplate = false")

    # Check if expected object has been recieved
    if ($result.GetType() -ne [System.Data.DataTable]) {
        return $result
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{bytes = $row[1]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
    Get information about connections and utilization
#>
function get_connections_data() {

    $result = (run_sql -Query "SELECT current_setting('max_connections')::integer max_connections
                                    , count(pid)::float current_connections  
                                    , trunc(count(pid)::float / current_setting('max_connections')::integer * 100) pct_used
                                 FROM pg_stat_activity").Trim()

    # Check if expected object has been recieved
    if ($result.GetType() -ne [System.Data.DataTable]) {
        return $result
    }

    return ( @{max = $result[0]; current = $result[1]; pct = $result[2]} | ConvertTo-Json -Compress)
}

<#
    Not implemented yet, under construction
    finction to get list of remote replica instances
    SUPERUSER privilege is required to get all information from pg_stat_replication 
    Or function with security definer has to be created to view full information about replication
#>
function list_standby_instances() {
    $result = (run_sql -Query 'select * from pg_stat_replication')

    # Check if expected object has been recieved
    if ($result.GetType() -ne [System.Data.DataTable]) {
        return $result
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
        $list.Add(@{'{#REPLICA}' = $row[0]})
    }
}

<#
    Not implemented yet, under construction
    Function to provide time of last successeful database backup
    As PostgreSQL doesn't have build-in mechanism to track backups - additional modifications for backup scripts has to be done
    Script which running pg_basebackup after completion will update postgres.pg_basebackups table with result of completed (failed or success) backup
    postgres.pg_basebackups:
    CREATE TABLE pg_basebackups
          id SERIAL PRIMARY KEY
        , parameters VARCHAR NOT NULL
        , begin_time DATE NOT NULL
        , end_time DATE
        , status VARCHAR  [ 'COMPLETED'
                            'COMPLETED WITH WARNINGS'
                            'FAILED'
                          ]
        CREATE INDEX ON pg_basebackups (end_time);

#>
function get_last_db_backup() {
    $result = (run_sql -Query "SELECT to_char(max(end_time),'DD/MM/YYYY HH24:MI:SS')
                                    , trunc(((EXTRACT(EPOCH FROM now()::timestamp) - EXTRACT(EPOCH FROM max(end_time)::timestamp))/60/60)::numeric, 4) hours_since
					             FROM postgres.pg_basebackups
							    WHERE status like 'COMPLETED%'" `
                       -CommandTimeout 30
                )

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{date = $result[0]; hours_since = $result[1]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Function to provide time of last succeseful archived log backup
    
    pg_stat_archiver was introduced in 9.4 
#>
function get_archiver_stat_data() {
    $result = (run_sql -Query "SELECT to_char(last_archived_time,'DD/MM/YYYY HH24:MI:SS')
                                    , trunc(((EXTRACT(EPOCH FROM now()::timestamp) - EXTRACT(EPOCH FROM last_archived_time::timestamp))/60/60)::numeric, 4) hours_since
                                    , failed_count
					             FROM pg_stat_archiver")

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{date = $result[0]; hours_since = $result[1]; failed_count = $result[2]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Function to get data about elevated roles who have privilegies above normal (SUPERUSER)
    TODO: Rewrite with CovertTo-Json
#>
function get_elevated_users_data(){
    $result = (run_sql -Query "SELECT rolname
                                    , 'SUPERUSER'
                                 FROM pg_roles
                                WHERE rolsuper = 't'")

    # Check if expected object has been recieved
    if ($result.GetType() -ne [System.Data.DataTable]) {
        return $result
    }

    $idx = 0
    $json = "{`n`"data`":`n`t[`n"

    # generate JSON
    foreach ($row in $result) {
        $json += "`t`t{`"" + $row.Split('|')[0].Trim() + "`":{`"privilege`":`"" + $row.Split('|')[1].Trim() + "`"}}"
        $idx++

        if ($idx -lt $result.Count) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

# execute required check
&$CheckType