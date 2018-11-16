#!/bin/pwsh

<#
    Create oracle user with the following privilegies
 
    SQL> create user c##zabbix identified by '<password>';
    SQL> grant select any dictionary to c##zabbix;
    SQL> alter user c##zabbix set container_data=all container=current;

#>

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,        # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,         # Host name
    [Parameter(Mandatory=$true, Position=3)][int]$Port = 1521,         # Port number, if required for non standart configuration, by default 1521
    [Parameter(Mandatory=$true, Position=4)][string]$Username = '',    # User name
    [Parameter(Mandatory=$true, Position=5)][string]$Password = '',    # Password
    [Parameter(Mandatory=$true, Position=6)][string]$Service = '',     # Service name
    [Parameter(Mandatory=$false, Position=7)][string]$Tablespace = '', # Tablespace name, for tablespace related checks
    [Parameter(Mandatory=$false, Position=8)][string]$Container_Id = 0 # Container ID
    )

<#
   OS statistics:
      v$ostat
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

    Set-Item -Path env:LD_LIBRARY_PATH -value "/usr/lib/oracle/18.3/client64/lib" | out-null
    #Process {
    #   try {
             $sql = 'set head off feedback off verify off echo off linesize 220 wrap on pagesize 0 trimspool on numwidth 50;
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
      write-host $Query
      write-host $_ $output
        return "ERROR: CONNECTION REFUSED"
    }
} 

<#
Function to check instance status, OPEN stands for OK, any other results is equalent to FAIL
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

    $result = @(run_sql -Query "select tablespace_name from dba_tablespaces where CONTENTS = 'PERMANENT'")

    #if ($tablespaces.GetType() -eq [System.String]) {
    if ($result.Trim() -Match '^ERROR') {
        # Instance is not available
        return $null
    }

    $idx = 0
    $json = "{ `n`t`"data`": [`n"

    # generate JSON
    foreach ($row in $result) {
        #$json += "`t`t{`"{#TABLEPACE_NAME}`": `"" + $row[0] + "`"}"
        $json += "`t`t{`"{#TABLESPACE_NAME}`" : `"" + $row + "`"}"

        $idx++

        if ($idx -lt $result.Length) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

function list_pdbs() {

    $result = (run_sql -Query 'select cdb from v$database')

    #if ($tablespaces.GetType() -eq [System.String]) {
    if ($result.Trim() -Match '^ERROR') {
        # Instance is not available or not container database
        return $null
    } elseif ($result.Trim() -eq 'NO') {
        # return empty json
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $result = @(run_sql -Query ("select con_id ||':'||name from v`$pdbs where name != 'PDB`$SEED'"))

    $idx = 0
    $json = "{ `n`t`"data`": [`n"
    # generate JSON
    foreach ($row in $result) {
        $json += "`t`t{`"{#CON_ID}`" : " + $row.Trim().Split(':')[0] + ", `"{#PDB_NAME}`" : `"" + $row.Trim().Split(':')[1] + "`"}"
        $idx++

        if ($idx -lt $result.Length) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

<#
Function to check instance status, ONLINE stands for OK, any other results is equalent to FAIL
#>
function get_pdb_state() {
    $result = (run_sql -Query ('select OPEN_MODE from v$pdbs where con_id=' + $Container_Id))
    # Check if expected object has been recieved
    if ($result.Trim() -NotMatch 'ERROR:') {
        return $result
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }
}

function list_pdbs_tablespaces() {

    $result = (run_sql -Query 'select cdb from v$database')

    #if ($tablespaces.GetType() -eq [System.String]) {
    if ($result.Trim() -Match '^ERROR') {
        # Instance is not available or not container database
        return $null
    } elseif ($result.Trim() -eq 'NO') {
        # return empty json
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $result = @(run_sql -Query ("select c.con_id||':'|| p.name||':'||c.tablespace_name 
                                  from cdb_tablespaces c, v`$pdbs p 
                                 where c.contents = 'PERMANENT' and p.name != 'PDB`$SEED' and c.con_id = p.con_id"))

    #if ($tablespaces.GetType() -eq [System.String]) {
    if ($result.Trim() -Match '^ERROR:') {
        # Instance is not available or not container database
        return $null
    }

    $idx = 0
    $json = "{ `n`t`"data`": [`n"
    # generate JSON
    foreach ($row in $result) {
        #$json += "`t`t{`"{#TABLEPACE_NAME}`": `"" + $row[0] + "`"}"
        $json += "`t`t{`"{#CON_ID}`" : " + $row.Trim().Split(':')[0] + ", `"{#PDB_NAME}`" : `"" + $row.Trim().Split(':')[1] + "`", `"{#TABLESPACE_NAME}`" : `"" + $row.Trim().Split(':')[2] + "`"}"

        $idx++

        if ($idx -lt $result.Length) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

function get_tbs_used_space() {
    $result = @(run_sql -Query ("select d.TABLESPACE_NAME 
                                      ||':'|| trunc(USED_PERCENT,2) 
                                      ||':'|| USED_SPACE * (select BLOCK_SIZE from dba_tablespaces t where TABLESPACE_NAME = d.TABLESPACE_NAME)
                                   from dba_tablespace_usage_metrics d
                                      , dba_tablespaces t
                                  where t.CONTENTS = 'PERMANENT'
                                    and t.TABLESPACE_NAME = d.TABLESPACE_NAME"))

    # Check if expected object has been recieved
    #if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {
    $idx = 1
    $json = "{`n"

    # generate JSON
    foreach ($row in $result) {
        $json += "`t`t`"" + $row.Trim().Split(':')[0] + "`":{`"pct`":`"" + $row.Trim().Split(':')[1] + "`",`"bytes`":`"" + $row.Trim().Split(':')[2] + "`"}"

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "}"

    return $json
}

function get_pdb_tbs_used_space() {
    $result = @(run_sql -Query ("select p.NAME
                                      ||':'|| d.TABLESPACE_NAME
                                      ||':'|| trunc(USED_PERCENT,2)
                                      ||':'|| USED_SPACE * (select BLOCK_SIZE 
                                                              from cdb_tablespaces t 
                                                             where TABLESPACE_NAME = d.TABLESPACE_NAME
                                                               and CON_ID = d.CON_ID)
                                   from cdb_tablespace_usage_metrics d
                                      , cdb_tablespaces t
                                      , v`$pdbs p
                                  where t.CONTENTS = 'PERMANENT'
                                    and t.TABLESPACE_NAME = d.TABLESPACE_NAME
                                    and t.CON_ID = d.CON_ID
                                    and p.CON_ID = d.CON_ID
                                  order by p.NAME, d.TABLESPACE_NAME"))

    $idx = 1
    $pdb = ''
    $first_pdb = $true
    $json = "{`n"

    # generate JSON
    foreach ($row in $result) {
        if ($pdb -ne $row.Trim().Split(':')[0]){
            if ($first_pdb -ne $true) {
                $json = "`t},`n"
            }
            $json += "`t`"" + $row.Trim().Split(':')[0] + "`":{`n"
           $json += "`t`t`"" + $row.Trim().Split(':')[1] + "`":{`"pct`":`"" + $row.Trim().Split(':')[2] + "`",`"bytes`":`"" + $row.Trim().Split(':')[3] + "`"}"
           $pdb = $row.Trim().Split(':')[0]
           $first_pdb = $false
        }
        else {
          $json += ",`t`t`"" + $row.Trim().Split(':')[1] + "`":{`"pct`":`"" + $row.Trim().Split(':')[2] + "`",`"bytes`":`"" + $row.Trim().Split(':')[3] + "`"}" 
        }

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "`t}`n}"
    
    return $json
}

function get_tbs_state(){

    $result = (run_sql -Query ("select tablespace_name
                                     ||':'|| STATUS
                                  from dba_tablespaces
                                 where contents = 'PERMANENT'"))

    # Check if expected object has been recieved
    #if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {
    $idx = 1
    $json = "{`n"

    # generate JSON
    foreach ($row in $result) {
        $json += "`t`t`"" + $row.Trim().Split(':')[0] + "`":{`"state`":`"" + $row.Trim().Split(':')[1] + "`"}"

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "}"

    return $json

}

function get_pdb_tbs_state(){

    $result = (run_sql -Query ("select name
                                     ||':'|| tablespace_name
                                     ||':'|| status
                                  from cdb_tablespaces t
                                     , v`$pdbs p
                                 where t.contents = 'PERMANENT'
                                   and t.con_id = p.con_id"))

    $idx = 1
    $pdb = ''
    $first_pdb = $true
    $json = "{`n"

    # generate JSON
    foreach ($row in $result) {
        if ($pdb -ne $row.Trim().Split(':')[0]){
            if ($first_pdb -ne $true) {
                $json = "`t},`n"
            }
            $json += "`t`"" + $row.Trim().Split(':')[0] + "`":{`n"
           $json += "`t`t`"" + $row.Trim().Split(':')[1] + "`":{`"state`":`"" + $row.Trim().Split(':')[2] + "`"}"
           $pdb = $row.Trim().Split(':')[0]
           $first_pdb = $false
        }
        else {
          $json += "`t`t,`"" + $row.Trim().Split(':')[1] + "`":{`"state`":`"" + $row.Trim().Split(':')[2] + "`"}"
        }

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "`t}`n}"

    return $json

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
    $result = (run_sql -Query ('select trunc(sum(PERCENT_SPACE_USED)-sum(PERCENT_SPACE_RECLAIMABLE), 2) from v$flash_recovery_area_usage'))

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
