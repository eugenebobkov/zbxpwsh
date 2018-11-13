#!/bin/pwsh

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,       # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,        # Host name
    [Parameter(Mandatory=$true, Position=3)][int]$Port = 5432,        # Port number
    [Parameter(Mandatory=$true, Position=4)][string]$Username = '',   # User name
    [Parameter(Mandatory=$false, Position=5)][string]$Database = ''   # Database name
    )

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

    #Process {
    #   try {
             $output += '' 
             # password should be provided in .pgpass file or cetrificate configured
             $Query | /usr/pgsql-10/bin/psql -t -U $Username -h $Hostname --no-password postgres | Where {$_ -ne ""} | Set-Variable output
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
        return "ERROR: CONNECTION REFUSED"
    }
} 

<#
Function to check instance status, ONLINE stands for OK, any other results is equalent to FAIL
#>
function get_instance_state() {
    $result = (run_sql -Query 'select count(*) from pg_database').Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return 'ONLINE'
    }
    else {
        return $result
    }
}

function get_version() {
    $result = (run_sql -Query 'select version()').Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return $result 
    }
    else {
        return $null
    }
}

function get_startup_time() {
    $result = (run_sql -Query "select pg_postmaster_start_time()").Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return $result
    }
    else {
        return $null
    }
}

function list_databases() {

    $databases = (run_sql -Query "select datname from pg_database where datistemplate = false").Trim()

    if ($result -Match '^ERROR:') {
        # Instance is not available
        return $null
    }


    $idx = 0
    $json = "{ `n`t`"data`": [`n"

    # generate JSON
    foreach ($row in $databases) {
    # The first row in the table is amount of rows and it will be skippes as it has type System.Int32
        $json += "`t`t{`"{#DATABASE}`": `"" + $row + "`"}"

        $idx++

        if ($idx -lt $databases.Length) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

function get_database_size() {
    $result = (run_sql -Query "select pg_database_size(datname) from pg_database where datname = '$Database'").Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return $result
    }
    else {
        return $null
    }
}

function get_backends_count() {
    $result = (run_sql -Query "select count(pid) from pg_stat_activity").Trim()

    # Check if expected object has been recieved
    if ($result -NotMatch '^ERROR:') {
        return $result
    }
    else {
        return $null
    }
}

function get_backends_utilization_pct() {
    $result = (run_sql -Query "select trunc(count(pid)::float / current_setting('max_connections')::integer * 100) from pg_stat_activity").Trim()

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
