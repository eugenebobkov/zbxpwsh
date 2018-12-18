#!/bin/pwsh

<#
    Created: xx/10/2018

    Parameters to modify in zabbix agent configuration file:
    # it will allow \ symbol to be used as part of InstanceName variable
    UnsafeUserParameters=1 
    
    UserParameter provided as part of oracle.conf file which has to be places in zabbix_agentd.d directory

    Create new profile with unlimited expire_time (or modify default)
    Create oracle user with the following privilegies
 
    SQL> create user zabbix identified by '<password>' profile service_profie;
    SQL> grant create session, select any dictionary to zabbix;
    (for PDB monitoring)
    SQL> alter user c##zabbix set container_data=all container=current;

    Change user's profile settings to ulimited life_time
#>

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,        # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,         # Host name
    [Parameter(Mandatory=$true, Position=3)][int]$Port = 1521,         # Port number, if required for non standart configuration, by default 1521
    [Parameter(Mandatory=$true, Position=4)][string]$Username = '',    # User name
    [Parameter(Mandatory=$true, Position=5)][string]$Password = '',    # Password
    [Parameter(Mandatory=$true, Position=6)][string]$Service = ''     # Service name
)

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$global:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Definition

Import-Module -Name "$global:RootPath\lib\Library-Common.psm1"
Import-Module -Name "$global:RootPath\lib\Library-StringCrypto.psm1"

<# Notes:
   OS statistics:
      v$ostat
#>

function run_sql() {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)][string]$Query,
        # Sum of $ConnectTimeout and $CommandTimeout must not be more than 30, as 30 is maximum timeout allowed for Zabbix agent befort its connection timed out by server
        [Parameter(Mandatory=$false)][int32]$ConnectTimeout = 5,      # Connect timeout, how long to wait for instance to accept connection
        [Parameter(Mandatory=$false)][int32]$CommandTimeout = 10      # Command timeout, how long sql statement will be running, if it runs longer - it will be terminated
    )

    # Add Oracle ODP.NET extention
    # TODO: Get rid of hardcoded locations and move it to a config file $RootDir/etc/<...env.conf...>
    # TODO: Unix implementation, [Environment]::OSVersion.Platform -eq Unix|Win32NT
    Add-Type -Path D:\oracle\product\18.0.0\client_1\odp.net\managed\common\Oracle.ManagedDataAccess.dll

    $dataSource = "(DESCRIPTION =
                       (ADDRESS = (PROTOCOL = TCP)(HOST = $Hostname)(PORT = $Port))
                       (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $Service))
                   )"
 
    If ($Password) {
        $DBPassword = Read-EncryptedString -InputString $Password -Password (Get-Content "$global:RootPath\etc\.pwkey")
    }

    # Create connection string
    $connectionString = "User Id=$Username; Password=$DBPassword; Data Source=$dataSource;"

    # How long scripts attempts to connect to instance
    # default is 15 seconds and it will cause saturation issues for Zabbix agent (too many checks) 
    $connectionString += "Connect Timeout = $ConnectTimeout;"

    # Create the connection object
    $connection = New-Object Oracle.ManagedDataAccess.Client.OracleConnection("$connectionString")

    # try to open connection
    try {
        [void]$connection.open()
        } 
    catch {
        # report error, sanitize it to remove IPs if there are any
        $error = $_.Exception.Message.Split(':',2)[1].Trim() -Replace ("(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", "xxx.xxx.xxx.xxx")
        Write-Log -Message $error
        return "ERROR: CONNECTION REFUSED: $error"
    }

    # Create command to run using connection
    $command = New-Object Oracle.ManagedDataAccess.Client.OracleCommand($Query)
    $command.Connection = $connection
    $command.CommandTimeout = $CommandTimeout

    $adapter = New-Object Oracle.ManagedDataAccess.Client.OracleDataAdapter($command)
    $dataTable = New-Object System.Data.DataTable

    try {
        # [void] simitair to | Out-Null, prevents posting output of Fill function (amount of rows returned), which will be picked up as function output
        [void]$adapter.Fill($dataTable)
        $result = $dataTable
    }
    catch {
        # report error, sanitize it to remove IPs if there are any
        $error = $_.Exception.Message.Split(':',2)[1].Trim() -Replace ("(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", "xxx.xxx.xxx.xxx")
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
    
    $result = (run_sql -Query 'SELECT status FROM v$instance')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 'OPEN') {
        return 'ONLINE'
    }
    #TODO: any other statuses to check?
    # data is not in [System.Data.DataTable] format
    else {
        return $result
    }
}

<#
    Function to get software version
#>
function get_version() {
    
    $result = (run_sql -Query 'SELECT banner version 
                                 FROM v$version')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{version = $result.Rows[0][0]} | ConvertTo-Json)
    }
    # data is not in [System.Data.DataTable] format
    else {
        return $result
    }    
}

<#
    Function to get instance startup timestamp
#>
function get_startup_time() {
    
    $result = (run_sql -Query "SELECT to_char(startup_time,'DD/MM/YYYY HH24:MI:SS') startup_time
                                 FROM v`$instance")

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{startup_time = $result.Rows[0][0]} | ConvertTo-Json)
    }
    # data is not in [System.Data.DataTable] format
    else {
        return $result
    } 
}

<#
    Function to list database tablespaces
#>
function list_tablespaces() {

    $result = (run_sql -Query "SELECT tablespace_name FROM dba_tablespaces WHERE contents = 'PERMANENT'")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
       $list.Add(@{'{#TABLESPACE_NAME}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json)
} 


<#
    Function to list ASM diskgroups
#>
function list_asm_diskgroups() {

    $result = (run_sql -Query 'SELECT name 
                                 FROM v$asm_diskgroup')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no asm diskgroups - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
       $list.Add(@{'{#ASM_DISKGROUP_NAME}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json)
}

<#
    Function to list guarantee restore points
#>
function list_guarantee_restore_points() {

    $result = (run_sql -Query "SELECT name FROM v`$restore_point 
                                WHERE guarantee_flashback_database = 'YES'")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no restore points - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
       $list.Add(@{'{#RESTORE_POINT_NAME}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json)
}

<#
    Function to get data for guarantee restore points
#>
function get_guarantee_restore_points_data(){
    $result = (run_sql -Query "SELECT name
                                    , to_char(time, 'DD/MM/YYYY HH24:MI:SS') date_created
                                    , storage_size
                                 FROM v`$restore_point 
                                WHERE guarantee_flashback_database = 'YES'")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no restore points - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $idx = 1

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`"" + $row[0] + "`":{`"date`":`"" + $row[1] + "`",`"used_bytes`":" + $row[2] + "}"

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "}"

    return $json
}

<#
    Function to get state of ASM diskgroups in the database
#>
function get_asm_diskgroups_state(){
    $result = (run_sql -Query 'SELECT name 
                                    , state
                                 FROM v$asm_diskgroup')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no asm diskgroups - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $idx = 1

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`"" + $row[0] + "`":{`"state`":`"" + $row[1] + "`"}"

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "}"

    return $json
}

<#
    Function to get data for asm diskgroups (used_pct, used_mb, max etc.)
#>
function get_asm_diskgroups_data(){
    $result = (run_sql -Query 'SELECT name
                                    , total_mb - free_mb used_mb
                                    , round((total_mb - free_mb)/total_mb * 100, 4) used_pct
                                    , total_mb
                                 FROM v$asm_diskgroup')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no asm diskgroups - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $idx = 1

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`"" + $row[0] + "`":{`"used_mb`":" + $row[1] + ",`"used_pct`":" + $row[2] + ",`"total_mb`":" + $row[3] + "}"

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "}"

    return $json
}

<#
    Function to list pluggable databases
#>
function list_pdbs() {

    $result = (run_sql -Query 'SELECT cdb 
                                 FROM v$database')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available or not container database
        return $result
    } 
    elseif ($result.Rows[0][0] -eq 'NO') {
        # return empty json
        return "{ `n`t`"data`":[`n`t]`n}"
    }

    $result = (run_sql -Query "SELECT name 
                                 FROM v`$pdbs 
                                WHERE name != 'PDB`$SEED'")

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
       $list.Add(@{'{#PDB_NAME}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json)
}

<#
    Function to list standby destinations
#>
function list_standby_databases() {

    $result = (run_sql -Query "SELECT destination
                                 FROM v`$archive_dest
                                WHERE target = 'STANDBY'")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no standby databases - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
       $list.Add(@{'{#STANDBY_DEST}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json)
}

<#
    Function to get data about standby destinations
#>
function get_standby_data(){

    $result = (run_sql -Query "SELECT destination
                                    , status
                                    , valid_now
                                 FROM v`$archive_dest
                                WHERE target = 'STANDBY'")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    } 
    # if there are no standby databases - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $idx = 1

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`"" + $row[0] + "`":{`"status`":`"" + $row[1] + "`",`"valid_now`":`"" + $row[2] + "`"}"

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "}"

    return $json
}

<#
    Function to get instance status, OPEN stands for OK, any other results are equalent to FAIL
#>
function get_pdb_state() {

    $result = (run_sql -Query "SELECT name
                                    , open_mode 
                                 FROM v`$pdbs 
                                WHERE name not in ('PDB`$SEED')")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no PDB databases - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $idx = 1

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`"" + $row[0] + "`":{`"state`":`"" + $row[1] + "`"}"

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "}"

    return $json
}

<#
    Function to provide list of tablespaces in pluggable databases
#>
function list_pdbs_tablespaces() {
    # Check if database is container
    $result = (run_sql -Query 'SELECT cdb 
                                 FROM v$database')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available or it's not a container database
        return $result
    } 
    elseif ($result.Rows[0][0] -eq 'NO') {
        # return empty json
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $result = (run_sql -Query "SELECT p.name
                                    , c.tablespace_name 
                                 FROM cdb_tablespaces c
                                    , v`$pdbs p 
                                WHERE c.contents = 'PERMANENT' 
                                  AND p.name != 'PDB`$SEED' 
                                  AND c.con_id = p.con_id")

    if (-Not $result.GetType() -eq [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no PDB - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
       $list.Add(@{'{#PDB_NAME}' = $row[0]; '{#TABLESPACE_NAME}' = $row[1]})
    }

    return (@{data = $list} | ConvertTo-Json)
}

<#
    Function to provide used space for tablespaces (excluding tablespaces of pluggable databases)
    Checks/Triggers for individual tablespaces are done by dependant items
#>
function get_tbs_space_data() {

<#    $result = (run_sql -Query "SELECT d.tablespace_name 
                                    , trunc(used_percent,2) used_pct
                                    , used_space * (SELECT block_size FROM dba_tablespaces t WHERE tablespace_name = d.tablespace_name) used_bytes
                                    , tablespace_size * (SELECT block_size FROM dba_tablespaces t WHERE tablespace_name = d.tablespace_name) max_bytes
                                 FROM dba_tablespace_usage_metrics d
                                    , dba_tablespaces t
                                WHERE t.contents = 'PERMANENT'
                                  AND t.tablespace_name = d.tablespace_name")
#>

    $result = (run_sql -Query "SELECT c.tablespace_name
                                    , round(((bytes_alloc - nvl(bytes_free,0))/bytes_max)*100, 2) used_pct
                                    , bytes_alloc-nvl(bytes_free,0) used_bytes
                                    , bytes_max max_bytes
                                 FROM ( SELECT sum(bytes) bytes_free
                                             , tablespace_name
                                          FROM dba_free_space 
                                         GROUP BY
                                               tablespace_name 
                                      ) a
                                    , ( SELECT sum(bytes) bytes_alloc 
                                             , sum(greatest(maxbytes, bytes)) bytes_max
                                             , tablespace_name 
                                          FROM dba_data_files 
                                         GROUP BY 
                                               tablespace_name 
                                      ) b
                                    , dba_tablespaces c
                                WHERE a.tablespace_name (+) = b.tablespace_name
                                  AND b.tablespace_name = c.tablespace_name
                                  AND c.contents = 'PERMANENT'
                                  AND c.status = 'ONLINE'")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $idx = 1

    # generate JSON to process by dependant items
    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`"" + $row[0] + "`":{`"used_pct`":" + $row[1] + ",`"used_bytes`":" + $row[2] + ",`"max_bytes`":" + $row[3] + "}"

        if ($idx -lt $result.Rows.Count) {
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
function get_pdbs_tbs_used_space() {
    $result = (run_sql -Query "SELECT p.name
                                    , d.tablespace_name
                                    , trunc(used_percent,2) used_pct
                                    , used_space * (SELECT block_size
                                                      FROM cdb_tablespaces t 
                                                     WHERE t.tablespace_name = d.tablespace_name
                                                       AND con_id = d.con_id) used_bytes
                                    , tablespace_size * (SELECT block_size
                                                           FROM cdb_tablespaces t 
                                                          WHERE t.tablespace_name = d.tablespace_name
                                                            AND con_id = d.con_id) max_bytes
                                 FROM cdb_tablespace_usage_metrics d
                                    , cdb_tablespaces t
                                    , v`$pdbs p
                                WHERE t.contents = 'PERMANENT'
                                  AND t.tablespace_name = d.tablespace_name
                                  AND t.con_id = d.con_id
                                  AND p.con_id = d.con_id
                                ORDER BY p.name, d.tablespace_name")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no PDB - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $idx = 1
    $pdb = ''
    $first_pdb = $true

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        if ($pdb -ne $row[0]){
            if ($first_pdb -ne $true) {
                $json += "`t},`n"
            }
            $json += "`"" + $row[0] + "`":{`n"
           $json += "`t`"" + $row[1] + "`":{`"used_pct`":" + $row[2] + ",`"used_bytes`":" + $row[3] + ",`"max_bytes`":" + $row[4] + "}"
           $pdb = $row[0]
           $first_pdb = $false
        }
        else {
          $json += "`t,`"" + $row[1] + "`":{`"used_pct`":" + $row[2] + ",`"used_bytes`":" + $row[3] + ",`"max_bytes`":" + $row[4] + "}" 
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
    Time in backup mode in hours
#>
function get_tbs_state(){

    $result = (run_sql -Query "SELECT t.tablespace_name
                                    , t.status
                                    , CASE
                                          WHEN (SELECT count(*)
                                                  FROM v`$backup b
                                                     , dba_data_files d
                                                 WHERE d.tablespace_name  = t.tablespace_name
                                                   AND d.file_id = b.file#
                                                   AND b.status = 'ACTIVE') = 0
                                               THEN 'NOT ACTIVE'
                                          ELSE 'ACTIVE'
                                      END backup_mode
                                    , (SELECT round((sysdate - nvl(min(b.time), sysdate)) * 24, 6)
                                         FROM v`$backup b
                                            , dba_data_files d
                                        WHERE d.tablespace_name  = t.tablespace_name
                                          AND d.file_id = b.file#
                                          AND b.status = 'ACTIVE') backup_time
                                 FROM dba_tablespaces t
                                WHERE t.contents = 'PERMANENT'"
              )

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $idx = 1

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`"" + $row[0] + "`":{`"state`":`"" + $row[1] + "`",`"backup_mode`":`"" + $row[2] + "`",`"backup_mode_hours_since`":" + $row[3] + "}"

        if ($idx -lt $result.Rows.Count) {
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
function get_pdbs_tbs_state(){

    $result = (run_sql -Query "SELECT p.name
                                    , t.tablespace_name
                                    , t.status
                                    , CASE
                                          WHEN (SELECT count(*)
                                                  FROM v`$backup b
                                                     , dba_data_files d
                                                 WHERE d.tablespace_name  = t.tablespace_name
                                                   AND d.file_id = b.file#
                                                   AND b.status = 'ACTIVE') = 0
                                               THEN 'NOT ACTIVE'
                                          ELSE 'ACTIVE'
                                      END backup_mode
                                    , (SELECT round((sysdate - nvl(min(b.time), sysdate)) * 24, 6)
                                         FROM v`$backup b
                                            , dba_data_files d
                                        WHERE d.tablespace_name  = t.tablespace_name
                                          AND d.file_id = b.file#
                                          AND b.status = 'ACTIVE') hours_since
                                 FROM cdb_tablespaces t
                                    , v`$pdbs p
                                WHERE t.contents = 'PERMANENT'
                                  AND t.con_id = p.con_id"
              )

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no PDB - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $idx = 1
    $pdb = ''
    $first_pdb = $true

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        if ($pdb -ne $row[0]){
            if ($first_pdb -ne $true) {
                $json += "`t},`n"
            }
            $json += "`"" + $row[0] + "`":{`n"
            $json += "`t`"" + $row[1] + "`":{`"state`":`"" + $row[2] + "`",`"backup_mode`":`"" + $row[3] + "`",`"backup_mode_hours_since`":" + $row[4] +"}"
            $pdb = $row[0]
            $first_pdb = $false
        }
        else {
            $json += "`t,`"" + $row[1] + "`":{`"state`":`"" + $row[2] + "`",`"backup_mode`":`"" + $row[3] + "`",`"backup_mode_hours_since`":" + $row[4] +"}"
        }

        $json += "`n"
        $idx++
    }

    $json += "`t}`n}"

    return $json
}

<#
    Function to provide percentage of current processes to maximum available
#>
function get_processes_data() {

    $result = (run_sql -Query "SELECT max(value) max_processes
                                    , count(p.pid) current_processes
                                    , trunc((count(p.pid) / max(v.value))*100, 2) pct_used
                                 FROM (SELECT value 
                                         FROM v`$parameter 
                                        WHERE name = 'processes') v  
                                    , v`$process p")

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return ( @{
                     max = $result.Rows[0][0]
                     current = $result.Rows[0][1]
                     pct = $result.Rows[0][2]
                 } | ConvertTo-Json)
    }
    else {
        return $result
    }
}

<#
    Function to provide used FRA space
#>
function get_fra_used_pct() {

    $result = (run_sql -Query 'SELECT trunc(sum(PERCENT_SPACE_USED)-sum(PERCENT_SPACE_RECLAIMABLE), 2) used_pct 
                                 FROM v$flash_recovery_area_usage')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{used_pct = $result.Rows[0][0]} | ConvertTo-Json)
    }
    else {
        return $result
    }    
}

<#
    Function to provide time of last successeful database backup
    
    For 11g, if it's timed out - following actions can be done:
    Option 1: SQL> exec dbms_stats.gather_fixed_objects_stats;
    Option 2: QUERIES ON V$RMAN_STATUS are very slow even after GATHER_FIXED_OBJECTS_STATS is run (Doc ID 1525917.1)
              SQL> exec dbms_stats.DELETE_TABLE_STATS('SYS','X$KCCRSR')
#>
function get_last_db_backup() {
    $result = (run_sql -Query "SELECT to_char(max(end_time), 'DD/MM/YYYY HH24:MI:SS') backup_date
                                    , round((sysdate - max(end_time)) * 24, 6) hours_since
					             FROM v`$rman_status
							    WHERE object_type in ('DB FULL', 'DB INCR')
							      AND status like 'COMPLETED%'" `
                       -CommandTimeout 30
                )

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return ( @{
                     date = $result.Rows[0][0]
                     hours_since = $result.Rows[0][1]
                 } | ConvertTo-Json)
    }
    else {
        return $result
    }
}

<#
    Function to provide time of last succeseful archived log backup

    For 11g, if it's timed out - following actions can be done:
    Option 1: SQL> exec dbms_stats.gather_fixed_objects_stats;
    Option 2: QUERIES ON V$RMAN_STATUS are very slow even after GATHER_FIXED_OBJECTS_STATS is run (Doc ID 1525917.1)
              SQL> exec dbms_stats.DELETE_TABLE_STATS('SYS','X$KCCRSR')

#>
function get_last_log_backup() {
    $result = (run_sql -Query "SELECT to_char(max(end_time), 'DD/MM/YYYY HH24:MI:SS') backup_date
                                    , round((sysdate - max(end_time)) * 24, 6) hours_since
					             FROM v`$rman_status
							    WHERE object_type in ('ARCHIVELOG')
							      AND status like 'COMPLETED%'"  `
                       -CommandTimeout 25
                )

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return ( @{
                     date = $result.Rows[0][0]
                     hours_since = $result.Rows[0][1]
                 } | ConvertTo-Json)
    }
    else {
        return $result
    }
}

<#
    Function to get data about users who have privilegies above normal (DBA, SYSDBA)
#>
function get_elevated_users_data(){
    $result = (run_sql -Query "SELECT u.username
                                    , 'DBA'
                                    , u.account_status
                                 FROM dba_users u
                                    , dba_role_privs r
                                WHERE u.username not in ('SYS','SYSTEM')
                                  AND u.username = r.grantee
                                  AND r.granted_role = 'DBA'
                                UNION ALL  
                               SELECT u.username
                                    , 'SYSDBA'
                                    , u.account_status
                                 FROM dba_users u
                                    , v`$pwfile_users p
                                WHERE u.username not in ('SYS','SYSTEM')
                                  AND u.username = p.username
                                  AND p.sysdba = 'TRUE'")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no such users - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{ `n`t`"data`": [`n`t]`n}"
    }

    $idx = 1

    # generate JSON
    $json = "{`n`"data`":`n`t[`n"

    foreach ($row in $result) {
        $json += "`t`t{`"" + $row[0] + "`":{`"privilege`":`"" + $row[1] + "`",`"account_status`":`"" + $row[2] + "`"}}"

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
        $idx++
    }

    $json += "`t]`n}"

    return $json
}

# execute required check
&$CheckType