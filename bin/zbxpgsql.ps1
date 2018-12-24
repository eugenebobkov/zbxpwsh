#!/bin/pwsh

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,       # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,        # Host name
    [Parameter(Mandatory=$true, Position=3)][int]$Port = 5432,        # Port number
    [Parameter(Mandatory=$true, Position=4)][string]$Username = '',   # User name
    [Parameter(Mandatory=$false, Position=5)][string]$Password = ''   # Password, not required if .pgpass file populated
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
    param (
        [Parameter(Mandatory=$true)][string]$Query,
        [Parameter(Mandatory=$false)][int32]$ConnectTimeout = 5,      # Connect timeout, how long to wait for instance to accept connection
        [Parameter(Mandatory=$false)][int32]$CommandTimeout = 10      # Command timeout, how long sql statement will be running, if it runs longer - it will be terminated
    )
    
    # DEBUG: Error in SQL execution will not terminate whole script and error output will be suppressed
    # $ErrorActionPreference = 'silentlycontinue'

    <#
        Sqlplus
    #> 

    # TODO: Implement .NET DBProvider using Npgsql https://www.npgsql.org

<#
 Add-Type -Path "C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Npgsql\v4.0_4.0.3.0__5d8b90d52f46fda7\Npgsql.dll"

 # PostgeSQL-style connection string
                $connstring = "Server=localhost;Port=5432;User Id=zabbixmon;Password=zabbix;Database=postgres;"

                # Making connection with Npgsql provider
                $conn = New-Object Npgsql.NpgsqlConnection($connstring)
                $conn.Open()
                # quite complex sql statement
                $sql = "SELECT * FROM simple_table";
                # data adapter making request from our connection
                $da = New-Object NpgsqlDataAdapter($sql, $conn)
                # i always reset DataSet before i do
                # something with it.... i don't know why :-)
                $dt = New-Object System.Data.DataTable
                $dt.Reset()
                # filling DataSet with result from NpgsqlDataAdapter
                $da.Fill($dt);
                # since it C# DataSet can handle multiple tables, we will select first

                # since we only showing the result we don't need connection anymore
                $conn.Close();
#>
    #  
    
    if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        $psql = "d:\PostgreSQL\11\bin\psql.exe"
    }
    else {
        $psql = "/usr/pgsql-10/bin/psql"
    }  

    # Set variable to PostgreSQL password file
    Set-Item -Path env:PGPASSFILE -Value "$global:RootPath\etc\.pgpass"

    #Process {
    #   try {
             $output += '' 
             # password should be provided in .pgpass file or cetrificate configured
             $Query | &$psql -t -U $Username -h $Hostname --no-password postgres | Where {$_ -ne ""} | Set-Variable output
             $rc = $LASTEXITCODE
    #    } 
    #    catch {
    #        $output = $null
    #    }     
    #}

    # Execution was succesful
    if ($rc -eq 0) {     
        return $output
    } 
    # issues during execution
    else {
        Write-Log -Message "$output"
        error = $output.Trim() -Replace ("(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", "xxx.xxx.xxx.xxx")
        return "ERROR: CONNECTION REFUSED: $error"
    }
} 

<#
    Function to check instance status, ONLINE stands for OK, any other results is equalent to FAIL
#>
function get_instance_state() {
    $result = (run_sql -Query 'SELECT count(*) 
                                 FROM pg_database').Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return 'ONLINE'
    }
    else {
        return $result
    }
}

<#
    Function to get software version
#>
function get_version() {
    $result = (run_sql -Query 'SELECT version()').Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return (@{version = $result.Trim()} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Function to get instance startup time
#>
function get_startup_time() {
    $result = (run_sql -Query "SELECT to_char(pg_postmaster_start_time(),'DD/MM/YYYY HH24:MI:SS')").Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return (@{startup_time = $result.Trim()} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Provide list of databases
#>
function list_databases() {

    $result = @(run_sql -Query 'SELECT datname 
                                  FROM pg_database 
                                 WHERE datistemplate = false').Trim()

    if ($result -Match '^ERROR:') {
        # Instance is not available
        return $result
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
       $list.Add(@{'{#DATABASE}' = $row})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)
}

<#
    Get information databases' size
#>
function get_databases_size() {

    $result = @(run_sql -Query "SELECT datname
                                     , pg_database_size(datname) 
                                  FROM pg_database 
                                 WHERE datistemplate = false").Trim()

    # Check if expected object has been recieved
    if ($result -Match '^ERROR:') {
        return $result
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row.Split('|')[0].Trim(), @{bytes = $row.Split('|')[1].Trim()})
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
    if ($result -Match '^ERROR:') {
        return $result
    }

    return ( @{
                max = $result.Split('|')[0].Trim()
                current = $result.Split('|')[1].Trim()
                pct = $result.Split('|')[2].Trim()
             } | ConvertTo-Json -Compress)
}

<#
    Not implemented yet, JSON expected
#>
function get_standby_instances() {
    $result = (run_sql -Query "").Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return $result
    }
    else {
        return $result
    }
}

<#
    Function to provide time of last successeful database backup
    As PostgreSQL doesn't have build in mechanism to track backups - additional modifications for backup scripts has to be done
    Script which running pg_basebackup after completion will update postgres.pg_basebackups table with result of completed (failed or success) backup
    postgres.pg_basebackups:
    CREATE TABLE pg_basebackups
          seq_id SERIAL PRIMARY KEY
        , begin_time DATE NOT NULL
        , end_time DATE
        , parameters varchar
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
    if ($result -NotMatch '^ERROR:') {
        return (@{
                    date = $result.Split('|')[0].Trim()
                    hours_since = $result.Split('|')[1].Trim()
                } | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Function to provide time of last succeseful archived log backup
    
    pg_stat_archiver was introduced in 9.4 
#>
function get_last_log_backup() {
    $result = (run_sql -Query "SELECT to_char(last_archived_time,'DD/MM/YYYY HH24:MI:SS')
                                    , trunc(((EXTRACT(EPOCH FROM now()::timestamp) - EXTRACT(EPOCH FROM last_archived_time::timestamp))/60/60)::numeric, 4) hours_since
                                    , failed_count
					             FROM pg_stat_archiver")

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return (@{
                    date = $result.Split('|')[0].Trim()
                    hours_since = $result.Split('|')[1].Trim()
                    failed_count = $result.Split('|')[2].Trim()
                } | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}


<#
    Function to get data about roles who have privilegies above normal (SUPERUSER)
#>
function get_elevated_users_data(){
    $result = (run_sql -Query "SELECT rolname
                                    , 'SUPERUSER'
                                 FROM pg_roles
                                WHERE rolsuper = 't'")

    # Check if expected object has been recieved
    if ($result -Match '^ERROR:') {
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
