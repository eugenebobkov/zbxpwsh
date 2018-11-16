#!/bin/pwsh

<#
    Created: xx/10/2018

    Parameters to modify in zabbix agent configuration file:
    # it will allow \ symbol to be used as part of InstanceName variable
    UnsafeUserParameters=1 
    
    UserParameter provided as part of oracle.conf file which has to be places in zabbix_agentd.d directory

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
    [Parameter(Mandatory=$false, Position=7)][string]$Container_Id = 0 # Container ID
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
    
    # Add Oracle ODP.NET extention
    Add-Type -Path D:\oracle\product\18.0.0\client_1\odp.net\managed\common\Oracle.ManagedDataAccess.dll

    $dataSource = "(DESCRIPTION =
                       (ADDRESS = (PROTOCOL = TCP)(HOST = $Hostname)(PORT = $Port))
                       (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $Service))
                   )"

    # Create connection string
    $oracleConnectionString = "User Id=$Username;Password=$Password;Data Source=$dataSource"

    # Create the connection object
    $oracleConnection = New-Object Oracle.ManagedDataAccess.Client.OracleConnection("$oracleConnectionString")
    
    # How long scripts attempts to connect to instance
    # default is 15 seconds and it will cause saturation issues for Zabbix agent (too many checks) 
    $OracleConnection.ConnectionTimeout = $ConnectTimeout
    
    # try to open connection
    try {
        [void]$oracleConnection.open()
        } 
    catch {
        write-Host $_
        return 'ERROR: CONNECTION REFUSED'
    }

    # Create command to run using connection
    $oracleCommand = New-Object Oracle.ManagedDataAccess.Client.OracleCommand
    $oracleCommand.Connection = $oracleConnection
    $oracleCommand.CommandText = $Query
    $oracleCommand.CommandTimeout = $CommandTimeout

    $oracleAdapter = New-Object Oracle.ManagedDataAccess.Client.OracleDataAdapter($oracleCommand)
    $dataTable = New-Object System.Data.DataTable

    try {
        [void]$oracleAdapter.Fill($dataTable)
        $result = $dataTable
    }
    catch {
        # TODO: better handling and logging for invalid statements
        # DEBUG: To print error
        Write-Host "$_"
        $result = 'ERROR: QUERY TIMED OUT'
    } 
    finally {
        $oracleConnection.Close()
    }

    # Comma in front is essential as without it return provides object's value, not object itselt
    return ,$result
} 

<#
Function to check instance status, OPEN stands for OK, any other results is equalent to FAIL
#>
function get_instance_state() {
    
    $result = (run_sql -Query 'SELECT status FROM v$instance')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 'OPEN') {
        return 'OPEN'
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }
    else {
        return 'ERROR: UNKNOWN'
    }
}

function get_version() {
    
    $result = (run_sql -Query 'SELECT banner FROM v$version')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        $result.Rows[0][0] 
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }    
    else {
        return 'ERROR: UNKNOWN'
    }
}

function get_startup_time() {
    
    $result = (run_sql -Query "SELECT to_char(startup_time,'DD/MM/YYYY HH24:MI:SS') FROM v`$instance")

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -Match '^\d\d/\d\d/\d\d\d\d \d\d:\d\d:\d\d$') {
        return $result.Rows[0][0]
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $null
    } 
    else {
        return 'ERROR: UNKNOWN'
    }
}

function list_tablespaces() {

    $result = (run_sql -Query "SELECT tablespace_name FROM dba_tablespaces WHERE contents = 'PERMANENT'")

    if ($result.GetType() -eq [System.String]) {
        # Instance is not available
        return $null
    }

    $idx = 0
    $json = "{ `n`t`"data`": [`n"

    # generate JSON
    foreach ($row in $result) {
        $json += "`t`t{`"{#TABLESPACE_NAME}`": `"" + $row[0] + "`"}"
        $idx++

        if ($idx -lt $result.Rows.Count()) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

function list_pdbs() {

    $result = (run_sql -Query 'select cdb from v$database')

    if ($result.GetType() -eq [System.String]) {
        # Instance is not available or not container database
        return $null
    } elseif ($result.Rows[0][0] -eq 'NO') {
        # return empty json
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $result = (run_sql -Query ("select con_id, name from v`$pdbs where name != 'PDB`$SEED'"))

    $idx = 0
    $json = "{ `n`t`"data`": [`n"
    # generate JSON
    foreach ($row in $result) {
        $json += "`t`t{`"{#CON_ID}`" : " + $row[0] + ", `"{#PDB_NAME}`" : `"" + $row[1] + "`"}"
        $idx++

        if ($idx -lt $result.Rows.Count()) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

<#
Function to get instance status, OPEN stands for OK, any other results are equalent to FAIL
#>
function get_pdb_state() {

    $result = (run_sql -Query ('SELECT open_mode FROM v$pdbs WHERE con_id=' + $Container_Id))

    # Check if expected object has been recieved
    
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return $result.Rows[0][0]
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }
}

<#
Function to provide list of tablespaces in pluggable databases
#>
function list_pdbs_tablespaces() {
    # Check if database is container
    $result = (run_sql -Query 'SELECT cdb FROM v$database')

    if ($result.GetType() -eq [System.String]) {
        # Instance is not available or not container database
        return $null
    } elseif ($result.Rows[0][0] -eq 'NO') {
        # return empty json
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $result = @(run_sql -Query ("SELECT c.con_id, p.name, c.tablespace_name 
                                   FROM cdb_tablespaces c, v`$pdbs p 
                                  WHERE c.contents = 'PERMANENT' AND p.name != 'PDB`$SEED' AND c.con_id = p.con_id"))

    if ($result.GetType() -eq [System.String]) {
        # Instance is not available or not container database
        return $null
    }

    $idx = 0
    # generate JSON
    $json = "{ `n`t`"data`": [`n"

    foreach ($row in $result) {
        $json += "`t`t{`"{#CON_ID}`" : " + $row[0] + ", `"{#PDB_NAME}`" : `"" + $row[1] + "`", `"{#TABLESPACE_NAME}`" : `"" + $row[2] + "`"}"

        $idx++

        if ($idx -lt $result.Rous.Count()) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

<#
Function to provide used space for tablespaces (excluding tablespaces of pluggable databases)
Checks/Triggers for individual tablespaces are done by dependant items
#>
function get_tbs_used_space() {

    $result = @(run_sql -Query ("SELECT d.TABLESPACE_NAME 
                                      , trunc(USED_PERCENT,2) 
                                      , USED_SPACE * (SELECT BLOCK_SIZE FROM dba_tablespaces t WHERE TABLESPACE_NAME = d.TABLESPACE_NAME)
                                   FROM dba_tablespace_usage_metrics d
                                      , dba_tablespaces t
                                  WHERE t.CONTENTS = 'PERMANENT'
                                    AND t.TABLESPACE_NAME = d.TABLESPACE_NAME"))

    if ($result.GetType() -eq [System.String]) {
        # Instance is not available
        return $result
    }

    $idx = 1

    # generate JSON to process by dependant items
    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`t`"" + $row[0] + "`":{`"pct`":`"" + $row[1] + "`",`"bytes`":`"" + $row[2] + "`"}"

        if ($idx -lt $result.Rows.Count()) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "}"

    return $json
}

<#
Function to provide used space for tablespaces of pluggable databases, excluding tablespaces in root container
Checks/Triggers for individual tablespaces are done by dependant items
#>
function get_pdb_tbs_used_space() {
    $result = @(run_sql -Query ("SELECT p.name
                                      , d.tablespace_name
                                      , trunc(used_percent,2)
                                      , USED_SPACE * (SELECT BLOCK_SIZE 
                                                        FROM cdb_tablespaces t 
                                                       WHERE TABLESPACE_NAME = d.TABLESPACE_NAME
                                                         AND CON_ID = d.CON_ID)
                                   FROM cdb_tablespace_usage_metrics d
                                      , cdb_tablespaces t
                                      , v`$pdbs p
                                  WHERE t.CONTENTS = 'PERMANENT'
                                    AND t.TABLESPACE_NAME = d.TABLESPACE_NAME
                                    AND t.CON_ID = d.CON_ID
                                    AND p.CON_ID = d.CON_ID
                                  ORDER BY p.NAME, d.TABLESPACE_NAME"))

    $idx = 1
    $pdb = ''
    $first_pdb = $true

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        if ($pdb -ne $row[0]){
            if ($first_pdb -ne $true) {
                $json = "`t},`n"
            }
            $json += "`t`"" + $row[0] + "`":{`n"
           $json += "`t`t`"" + $row[1] + "`":{`"pct`":`"" + $row[2] + "`",`"bytes`":`"" + $row[3] + "`"}"
           $pdb = $row.Trim().Split(':')[0]
           $first_pdb = $false
        }
        else {
          $json += ",`t`t`"" + $row[1] + "`":{`"pct`":`"" + $row[2] + "`",`"bytes`":`"" + $row[3] + "`"}" 
        }

        if ($idx -lt $result.Rows.Count()) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "`t}`n}"
    
    return $json
}

<#
Function to provide state for tablespaces (excluding tablespaces of pluggable databases)
Checks/Triggers for individual tablespaces are done by dependant items
#>
function get_tbs_state(){

    $result = (run_sql -Query ("SELECT tablespace_name
                                     , status
                                  FROM dba_tablespaces
                                 WHERE contents = 'PERMANENT'"))

    if ($result.GetType() -eq [System.String]) {
        # Instance is not available
        return $result
    }

    $idx = 1

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`t`"" + $row[0] + "`":{`"state`":`"" + $row[1] + "`"}"

        if ($idx -lt $result.Rows.Count()) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "}"

    return $json
}

<#
Function to provide state for tablespaces of pluggable databases, excluding tablespaces in root container
Checks/Triggers for individual tablespaces are done by dependant items
#>
function get_pdb_tbs_state(){

    $result = (run_sql -Query ("SELECT p.name
                                     , t.tablespace_name
                                     , t.status
                                  FROM cdb_tablespaces t
                                     , v`$pdbs p
                                 WHERE t.contents = 'PERMANENT'
                                   AND t.con_id = p.con_id"))

    $idx = 1
    $pdb = ''
    $first_pdb = $true

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        if ($pdb -ne $row[0]){
            if ($first_pdb -ne $true) {
                $json = "`t},`n"
            }
            $json += "`t`"" + $row[0] + "`":{`n"
           $json += "`t`t`"" + $row[1] + "`":{`"state`":`"" + $row[2] + "`"}"
           $pdb = $row[0]
           $first_pdb = $false
        }
        else {
          $json += "`t`t,`"" + $row[1] + "`":{`"state`":`"" + $row[2] + "`"}"
        }

        if ($idx -lt $result.Rows.Count()) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "`t}`n}"

    return $json
}

<#
Function to provide amount of processes
#>
function get_current_processes() {
    $result = (run_sql -Query ('SELECT count(*) FROM v$process'))

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return $result.Rows[0][0]
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $null
    }
    else {
        return 'ERROR: UNKNOWN'
    }
}

<#
Function to provide percentage of current processes to maximum available
#>
function get_utilization_processes_pct() {

    $result = (run_sql -Query ("SELECT round((count(p.pid) / max(v.value))*100)    `
                                  FROM (SELECT value FROM v`$parameter WHERE name = 'processes') v  `
                                     , v`$process p"))

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return $result.Rows[0][0]
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $null
    }
    else {
        return 'ERROR: UNKNOWN'
    }
}

<#
Function to provide used FRA space
#>
function get_fra_used_pct() {

    $result = (run_sql -Query ('SELECT trunc(sum(PERCENT_SPACE_USED)-sum(PERCENT_SPACE_RECLAIMABLE), 2) FROM v$flash_recovery_area_usage'))

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return $result.Rows[0][0]
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $null
    }    
    else {
        return 'ERROR: UNKNOWN'
    }
}

# execute required check
&$CheckType
