#!/bin/pwsh

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,       # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,        # Host name
    [Parameter(Mandatory=$true, Position=3)][int]$Port = 1521,        # Port number, if required for non standart configuration, by default 1521
    [Parameter(Mandatory=$true, Position=4)][string]$Username = '',   # User name
    [Parameter(Mandatory=$true, Position=5)][string]$Password = '',   # Password
    [Parameter(Mandatory=$true, Position=6)][string]$Service = '',    # Service name
    [Parameter(Mandatory=$false, Position=7)][string]$Tablespace = '' # Tablespace name, for tablespace related checks
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

    Set-Item -Path env:LD_LIBRARY_PATH -value "/usr/lib/oracle/18.3/client64/lib" | out-null
   
    #Process {
    #   try {
             $sql = 'set head off feedback off verify off echo off linesize 220 wrap on pagesize 0 trimspool on;
                     whenever sqlerror exit 255;
                     whenever oserror exit 255;
                    '
             $sql += $Query + ';'
             $output += '' 
             $sql | /usr/lib/oracle/18.3/client64/bin/sqlplus -s $Username/$Password@"$Hostname":$Port/"$Service" | Set-Variable output
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
    $result = (run_sql -Query 'select status from v$instance')

    # Check if expected object has been recieved
    #if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {
    if ($result.Trim() -eq 'OPEN') {
        return 'OPEN'
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }
}

function get_version() {
    $result = (run_sql -Query 'show rel')

    # Check if expected object has been recieved
    #if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {
    if ($result.Trim() -Match 'release \d{10}') {
        return ($result.Trim() -Split ' ')[1] 
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }
}

function get_startup_time() {
    $result = (run_sql -Query "select to_char(STARTUP_TIME,'DD/MM/YYYY HH24:MI:SS') from v`$instance")

    # Check if expected object has been recieved
    #if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {
    
    if ($result.Trim() -Match '^\d\d/\d\d/\d\d\d\d \d\d:\d\d:\d\d$') {
        return $result.Trim()
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $null
    }
}

function list_tablespaces() {

    $tablespaces = (run_sql -Query "select tablespace_name from dba_tablespaces where CONTENTS = 'PERMANENT'")

    if ($tablespaces.GetType() -eq [System.String]) {
        # Instance is not available
        return $null
    }

    $idx = 0
    $json = "{ `n`t`"data`": [`n"

    # generate JSON
    foreach ($row in $tablespaces) {
    # The first row in the table is amount of rows and it will be skippes as it has type System.Int32
        #$json += "`t`t{`"{#TABLEPACE_NAME}`": `"" + $row[0] + "`"}"
        $json += "`t`t{`"{#TABLESPACE_NAME}`": `"" + $row + "`"}"

        $idx++

        if ($idx -lt $tablespaces.Length) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

function get_tbs_used_space_pct() {
    $result = (run_sql -Query ("select USED_PERCENT from dba_tablespace_usage_metrics where tablespace_name='" + $Tablespace + "'"))

    # Check if expected object has been recieved
    #if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {
    
    if ($result.Trim() -Match '^[\d|\.]') {
        return $result.Trim()
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $null
    }
}

function get_tbs_used_space_bytes() {
    $result = (run_sql -Query ("select USED_SPACE * (select BLOCK_SIZE from dba_tablespaces t where TABLESPACE_NAME = d.TABLESPACE_NAME) `
                                  from dba_tablespace_usage_metrics d
                                 where  tablespace_name='" + $Tablespace + "'"))

    # Check if expected object has been recieved
    #if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {

    if ($result.Trim() -Match '^[\d]') {
        return $result.Trim()
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $null
    }
}

function get_tbs_max_space_bytes() {
    $result = (run_sql -Query ("select TABLESPACE_SIZE * (select BLOCK_SIZE from dba_tablespaces t where TABLESPACE_NAME = d.TABLESPACE_NAME) `
                                  from dba_tablespace_usage_metrics d
                                 where  tablespace_name='" + $Tablespace + "'"))

    # Check if expected object has been recieved
    #if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {

    if ($result.Trim() -Match '^[\d]') {
        return $result.Trim()
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $null
    }
}

function get_tbs_state(){

    $result = (run_sql -Query ("select STATUS
                                  from dba_tablespaces
                                 where  tablespace_name='" + $Tablespace + "'"))

    # Check if expected object has been recieved
    #if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {

    if ($result.Trim() -Match '^ERROR') {
        return $result.Trim()
    }
    else {
        return $result.Trim()
    }

}

function get_current_processes() {
    $result = (run_sql -Query ('select count(*) from v$process'))

    # Check if expected object has been recieved
    #if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {

    if ($result.Trim() -Match '^[\d]') {
        return $result.Trim()
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $null
    }
}

function get_utilization_processes_pct() {
    $result = (run_sql -Query ("select round((count(p.pid) / max(v.value))*100)    `
                                  from (select VALUE from v`$parameter where name = 'processes') v  `
                                     , v`$process p"))

    # Check if expected object has been recieved
    #if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {

    if ($result.Trim() -Match '^[\d]') {
        return $result.Trim()
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $null
    }
}

function get_fra_used_pct() {
    $result = (run_sql -Query ('select sum(PERCENT_SPACE_USED)-sum(PERCENT_SPACE_RECLAIMABLE) from v$flash_recovery_area_usage'))

    # Check if expected object has been recieved
    #if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {

    if ($result.Trim() -Match '^[\d]') {
        return $result.Trim()
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $null
    }
}

# execute required check
&$CheckType
