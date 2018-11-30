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
    [CmdletBinding()]
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
    if ($rc -eq 0) {       
        return $output
    } 
    else {
        Write-Log -Message $output
        return "ERROR: CONNECTION REFUSED: $output"
    }
} 

<#
Function to check instance status, ONLINE stands for OK, any other results is equalent to FAIL
#>
function get_instance_state() {
    $result = (run_sql -Query 'SELECT count(*) FROM pg_database').Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return 'ONLINE'
    }
    else {
        return $result
    }
}

function get_version() {
    $result = (run_sql -Query 'SELECT version()').Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return $result 
    }
    else {
        return $null
    }
}

<#
Function to get instance startup timestamp
#>
function get_startup_time() {
    $result = (run_sql -Query "SELECT pg_postmaster_start_time()").Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return $result
    }
    else {
        return $null
    }
}

function list_databases() {

    $result = @(run_sql -Query "SELECT datname FROM pg_database WHERE datistemplate = false").Trim()

    if ($result -Match '^ERROR:') {
        # Instance is not available
        return $null
    }

    $idx = 0
    $json = "{ `n`t`"data`": [`n"

    # generate JSON
    foreach ($row in $result) {
        $json += "`t`t{`"{#DATABASE}`": `"" + $row + "`"}"
        $idx++

        if ($idx -lt $result.Count) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

function get_databases_size() {

    $result = @(run_sql -Query "SELECT datname, pg_database_size(datname) FROM pg_database WHERE datistemplate = false").Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {

        $idx = 0
        $json = "{`n"

        # generate JSON
        foreach ($row in $result) {
            $json += "`t`"" + $row.Split('|')[0].Trim() + "`":{`"bytes`":`"" + $row.Split('|')[1].Trim() + "`"}"
            $idx++

            if ($idx -lt $result.Count) {
                $json += ','
            }
            $json += "`n"
        }

        $json += "}"

        return $json
    }
    else {
        return $null
    }
}

function get_connections_data() {

    $result = (run_sql -Query "SELECT  current_setting('max_connections')::integer   max_connections
                                     , count(pid)::float current_connections  
                                     , trunc(count(pid)::float / current_setting('max_connections')::integer * 100) pct_used
                                 FROM pg_stat_activity").Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return "{`n`t`"connections`": {`n`t`t `"max`":" + $result.Split('|')[0].Trim() + ",`"current`":" + $result.Split('|')[1].Trim() + ",`"pct`":" + $result.Split('|')[2].Trim() + "`n`t}`n}"
    }
    else {
        return $null
    }
}

function get_standby_instances() {
    $result = (run_sql -Query "").Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return $result
    }
    else {
        return $null
    }
}

# execute required check
&$CheckType
