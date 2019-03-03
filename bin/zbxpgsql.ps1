#!/bin/pwsh

<#
.SYNOPSIS
    Monitoring script for PostgreSQL RDBMS, intended to be executed by Zabbix Agent

.DESCRIPTION
    Connects to PostgreSQL using .NET dll files in $global:RootPath\dll folder
    UserParameter provided in pgsql.conf file which can be found in $global:RootPath\zabbix_agentd.d directory

.PARAMETER CheckType
    This parameter provides name of function which is required to be executed

.PARAMETER Hostname
    Hostname or IP adress of the server where required PostgreSQL instance is running

.PARAMETER Port
    TCP port, normally 5432

.PARAMETER Username
    PostgreSQL user/role used by Zabbix:
    psql> create user svc_zabbix with password '<password>';
    psql> alter role svc_zabbix with login;
    TODO: For somechecks SUPERUSER is required, for example list_standby_instances, but it's under construction
    Update pg_hba.conf with user's details if required 
    Reload PostgreSQL
    $ pg_ctl reload

.PARAMETER Password
    Encrypted password for PostgreSQL user. Encrypted string can be generated with $global:RootPath\bin\pwgen.ps1

.NOTES
    Version:        1.0
    Author:         Eugene Bobkov
    Creation Date:  xx/10/2018

    Checkpoint interval
        pg_stat_bgwriter
        pg_stat_replication - function with security definer has to be created to view full information about replication
        pg_locks - locks in the cluster
 
.EXAMPLE
    powershell -NoLogo -NoProfile -NonInteractive -executionPolicy Bypass -File D:\DBA\zbxpwsh\bin\zbxpgsql.ps1 -CheckType get_instance_state -Hostname pgsql_server -Port 5432 -Username svc_zabbix -Password sefrwe7soianfknewker79s=
#>

param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,       # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,        # Host name
    [Parameter(Mandatory=$true, Position=3)][int]$Port,               # Port number
    [Parameter(Mandatory=$true, Position=4)][string]$Username = '',   # User name
    [Parameter(Mandatory=$true, Position=5)][string]$Password = ''    # Password
)

$global:RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$global:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Definition

Import-Module -Name "$global:RootPath\lib\Library-Common.psm1"
Import-Module -Name "$global:RootPath\lib\Library-StringCrypto.psm1"

<#
.SYNOPSIS
    Internal function to connect to an instance and execute required sql statement

.PARAMETER Query
    Text of SQL Statement which is required to be executed

.PARAMETER ConnectTimeout
    Maxtimum wait time for establishing connection with the instance. Default is 5 seconds

.PARAMETER CommandTimeout
    Maxtimum wait time for the query execution. Default is 10 seconds

.NOTES
    In normal circumstances the functions returns query result as [System.Data.DataTable] 
    If query cannot be executed or return an error - the error will be returned as [System.String] and processed based on logic in parent function

.EXAMPLE
    PS> $result = (run_sql -Query 'SELECT count(*) FROM pg_database')
    PS> $result.Rows[0][0]
    4
#>
function run_sql() {
    param (
        [Parameter(Mandatory=$true)][string]$Query,
        [Parameter(Mandatory=$false)][int32]$ConnectTimeout = 5,      # Connect timeout, how long to wait for instance to accept connection
        [Parameter(Mandatory=$false)][int32]$CommandTimeout = 10      # Command timeout, how long sql statement will be running, if it runs longer - it will be terminated
    )
    
    # DEBUG: Error in SQL execution will not terminate whole script and error output will be suppressed
    # $ErrorActionPreference = 'silentlycontinue'

    # Load ADO.NET extentions required for creation of connection to PostgreSQL instance
    Add-Type -Path $global:RootPath\dll\System.Runtime.CompilerServices.Unsafe.dll
    Add-Type -Path $global:RootPath\dll\System.ValueTuple.dll
    Add-Type -Path $global:RootPath\dll\System.Threading.Tasks.Extensions.dll
    Add-Type -Path $global:RootPath\dll\Npgsql.dll

    # Decrypt password
    if ($Password -ne '') {
        $dbPassword = Read-EncryptedString -InputString $Password -Password (Get-Content "$global:RootPath\etc\.pwkey")
    } else {
        $dbPassword = ''
    }

    # Create connection string
    $connectionString = "Server = $Hostname; Port = $Port; Database = postgres; User Id = $Username; Password = $DBPassword;"

    # How long scripts attempts to connect to instance and for how long query will be running
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

    # Run query
    try {
        # [void] similair to | Out-Null, prevents posting output of Fill function (number of rows returned), which will be picked up as function output
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

    # Comma in front is essential as without it result is provided as object's value, not object itself
    return ,$result
} 

<#
.SYNOPSIS
    Function to return status of the instance, ONLINE stands for OK, any other results should be considered as FAIL
#>
function get_instance_state() {
    $result = (run_sql -Query 'SELECT count(*) 
                                 FROM pg_database')

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
.SYNOPSIS
    Function to return software version
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
.SYNOPSIS
    Function to return instance startup timestamp
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

<#
.SYNOPSIS
    Function to return list of databases in the cluster

.NOTES
    Used by discovery
#>
function list_databases() {
    # get list of databases
    $result = (run_sql -Query 'SELECT datname 
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
.SYNOPSYS
    Function to return size for all databases
#>
function get_databases_size() {
    # get size of all databases
    $result = (run_sql -Query 'SELECT datname
                                    , pg_database_size(datname) 
                                 FROM pg_database 
                                WHERE datistemplate = false')

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
.SYNOPSYS
    Function to return information about connections and utilization
#>
function get_connections_data() {
    # get data about current number of connections, value of max_connections parameter and percentage of utilization
    $result = (run_sql -Query "SELECT current_setting('max_connections')::integer max_connections
                                    , count(pid)::float current_connections  
                                    , trunc(count(pid)::float / current_setting('max_connections')::integer * 100) pct_used
                                 FROM pg_stat_activity")

    # Check if expected object has been recieved
    if ($result.GetType() -ne [System.Data.DataTable]) {
        return $result
    }

    return (@{max = $result.Rows[0][0]; current = $result.Rows[0][1]; pct_used = $result.Rows[0][2]} | ConvertTo-Json -Compress)
}

<#
.SYNOPSYS
    Function to return list of remote replica instances

.NOTES
    Not implemented yet, under construction
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

    return (@{data = $list} | ConvertTo-Json -Compress)
}

<#
.SYNOPSYS
    Function to return time of the last successeful database backup

.NOTES
    Not implemented yet, under construction
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
                       -CommandTimeout 30)

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{date = $result.Rows[0][0]; hours_since = $result.Rows[0][1]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
.SYNOPSYS
    Function to provide time of last succeseful archived log backup

.NOTES
    pg_stat_archiver was introduced in 9.4 
#>
function get_archiver_stat_data() {
    $result = (run_sql -Query "SELECT to_char(last_archived_time,'DD/MM/YYYY HH24:MI:SS')
                                    , trunc(((EXTRACT(EPOCH FROM now()::timestamp) - EXTRACT(EPOCH FROM last_archived_time::timestamp))/60/60)::numeric, 4) hours_since
                                    , failed_count
					             FROM pg_stat_archiver")

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{date = $result.Rows[0][0]; hours_since = $result.Rows[0][1]; failed_count = $result.Rows[0][2]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
.SYNOPSYS
    Function to get data about elevated roles who have privilegies above normal (SUPERUSER)

.NOTES
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
        $json += "`t`t{`"" + $row[0] + "`":{`"privilege`":`"" + $row[1] + "`"}}"
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