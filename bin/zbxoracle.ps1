#!/bin/pwsh

<#
    Created: xx/10/2018

    Parameters to modify in zabbix agent configuration file:
    # it will allow \ symbol to be used as part of InstanceName variable
    UnsafeUserParameters=1 
    
    UserParameter provided as part of oracle.conf file which has to be places in zabbix_agentd.d directory

    Create new profile with unlimited expire_time (or modify default)
    SQL> CREATE PROFILE monitoring_profile LIMIT PASSWORD_LIFE_TIME unlimited FAILED_LOGIN_ATTEMPTS;

    Create oracle user and grant the following privilegies
 
    SQL> create user svc_zabbix identified by '<password>' profile monitoring_profie;
    SQL> grant create session, select any dictionary to svc_zabbix;
    (for PDB monitoring)
    SQL> alter user c##svc_zabbix set container_data=all container=current;
#>

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,        # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,         # Host name
    [Parameter(Mandatory=$true, Position=6)][string]$Service ,         # Service name
    [Parameter(Mandatory=$true, Position=3)][int]$Port = 1521,         # Port number, if required for non standart configuration, by default 1521
    [Parameter(Mandatory=$true, Position=4)][string]$Username,         # User name
    [Parameter(Mandatory=$true, Position=5)][string]$Password          # Password
)

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$global:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Definition

Import-Module -Name "$global:RootPath\lib\Library-Common.psm1"
Import-Module -Name "$global:RootPath\lib\Library-StringCrypto.psm1"

<# Notes:
   OS statistics:
      v$ostat
      V$SYSTEM_WAIT_CLASS
#>

<#
    Internal function to run provided sql statement. If for some reason it cannot be executed - it returns error as [System.String]
#>
function run_sql() {
    param (
        [Parameter(Mandatory=$true)][string]$Query,
        # Sum of $ConnectTimeout and $CommandTimeout must not be more than 30, as 30 is maximum timeout allowed for Zabbix agent (4.0) before its connection timed out by server
        [Parameter(Mandatory=$false)][int32]$ConnectTimeout = 5,      # Connect timeout, how long to wait for instance to accept connection
        [Parameter(Mandatory=$false)][int32]$CommandTimeout = 10      # Command timeout, how long sql statement will be running, if it runs longer - it will be terminated
    )

    # Add Oracle ODP.NET extention
    # TODO: Get rid of hardcoded locations and move it to a config file $RootDir/etc/<...env.conf...>
    # TODO: Unix implementation, [Environment]::OSVersion.Platform -eq Unix|Win32NT
    Add-Type -Path D:\oracle\product\18.0.0\client_1\odp.net\bin\4\Oracle.DataAccess.dll

    $dataSource = "(DESCRIPTION =
                       (ADDRESS = (PROTOCOL = TCP)(HOST = $Hostname)(PORT = $Port))
                       (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = $Service))
                   )"
 
    if ($Password -ne '') {
        $dbPassword = Read-EncryptedString -InputString $Password -Password (Get-Content "$global:RootPath\etc\.pwkey")
    } else {
        $dbPassword = ''
    }

    # Create connection string

    # check for sysdba or equalent privilegies
    if ($Username.Split().Count -gt 1) {
        $dbUsername = $Username.Split()[0]
        $dbDBAPrivilege = $Username.Split()[2].ToUpper()

        # Assamble connection string
        $connectionString = "User Id=$dbUsername; Password=$dbPassword; DBA Privilege=$dbDBAPrivilege; Data Source=$dataSource;"
    }
    else {
        $connectionString = "User Id=$Username; Password=$dbPassword; Data Source=$dataSource;"
    }

    # How long scripts attempts to connect to instance
    # default is 15 seconds and it will cause saturation issues for Zabbix agent (too many checks) 
    $connectionString += "Connect Timeout = $ConnectTimeout;"

    # Create the connection object
    $connection = New-Object Oracle.DataAccess.Client.OracleConnection("$connectionString")

    # try to open connection
    try {
        [void]$connection.open()
        } 
    catch {
        # report error, sanitize it to remove IPs if there are any
        $error = $_.Exception.Message.Split(':',2)[1].Trim() -Replace ("(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", "xxx.xxx.xxx.xxx")
        Write-Log -Message ('[' + $Hostname + ':' + $CheckType + '] ' + $error)
        return "ERROR: CONNECTION REFUSED: $error"
    }

    # Create command to run using connection
    $command = New-Object Oracle.DataAccess.Client.OracleCommand($Query)
    $command.Connection = $connection
    $command.CommandTimeout = $CommandTimeout

    $adapter = New-Object Oracle.DataAccess.Client.OracleDataAdapter($command)
    $dataTable = New-Object System.Data.DataTable

    try {
        # [void] similair to | Out-Null, prevents posting output of Fill function (number of rows returned), which will be picked up as function output
        [void]$adapter.Fill($dataTable)
        $result = $dataTable
    }
    catch {
        # report error, sanitize it to remove IPs if there are any
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
    Internal function to check if instance is available and has container datababase functionality
#>
function is_available_and_cdb() {
    # check database version, cdb was implemented starting from version 12
    $result = (run_sql -Query 'SELECT version 
                                 FROM v$instance')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available 
        return $false
    } 
    elseif ([int]$result.Rows[0][0].Split('.')[0] -le 11) {
        # return $false, this version doesn't have CDB functionality
        return $false
    }

    # Check if database is container
    $result = (run_sql -Query 'SELECT cdb 
                                 FROM v$database')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available or it's not a container database
        return $false
    } 
    elseif ($result.Rows[0][0] -eq 'NO') {
        # return empty json
        return $false
    } elseif ($result.Rows[0][0] -eq 'YES') {
        # this instance has container database
        return $true
    }
}

<#
    Function to check instance status, ONLINE stands for OK, any other results is equalent to FAIL
#>
function get_instance_state() {
    # get database response, fact of recieving data itself can be considered as good sign of the database availability
    $result = (run_sql -Query "SELECT i.status || DECODE ( d.controlfile_type
                                                         , 'CURRENT', NULL
                                                         , ':' || d.controlfile_type
                                                  )
                                 FROM v`$instance i
                                    , v`$database d")

    #TODO: any other statuses to check?
    # The instance in primary and accessible or standby and accessible
    if ($result.GetType() -eq [System.Data.DataTable] -And ($result.Rows[0][0] -eq 'OPEN' -Or $result.Rows[0][0] -eq 'MOUNTED:STANDBY' -Or $result.Rows[0][0] -eq 'OPEN:STANDBY')) {
        return 'ONLINE'
    # The instance in unexpected mode
    } elseif ($result.GetType() -eq [System.Data.DataTable]) {
        return $result.Rows[0][0]
    } else {
        # data is not in [System.Data.DataTable] format
        return $result
    }
}

<#
    Function to check instance role, OPEN stands for primary, [MOUNT|OPEN]:[STANDBY MODE] stands for standby database (including Active standby mode)
#>
function get_instance_role() {
    # get current status ans database role
    $result = (run_sql -Query "SELECT i.status || ':' || d.database_role
                                 FROM v`$instance i
                                    , v`$database d")

    #TODO: any other statuses to check?
    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{role = $result.Rows[0][0]} | ConvertTo-Json -Compress)
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
    $result = (run_sql -Query 'SELECT banner version 
                                 FROM v$version')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{version = $result.Rows[0][0]} | ConvertTo-Json -Compress)
    }
    # data is not in [System.Data.DataTable] format
    else {
        return $result
    }    
}

<#
    Function to get instances for the database. More than one instance is relevant for RAC configuration
#>
function list_instances() {
    # get instance startup time
    $result = (run_sql -Query 'SELECT instance_name
                                 FROM gv$instance')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
        $list.Add(@{'{#INSTANCE_NAME}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)
}

<#
    Function to get instance(s) data
#>
function get_instances_data() {
    # get instance startup time
    $result = (run_sql -Query "SELECT instance_name
                                    , to_char(startup_time,'DD/MM/YYYY HH24:MI:SS') startup_time
                                    , host_name
                                 FROM gv`$instance")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{startup_time = $row[1]; host_name = $row[2]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
    Function to get overall database size
#>
function get_database_size() {
    # get instance startup time
    $result = (run_sql -Query 'select sum(bytes) database_size
                                 from dba_segments')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{database_size = $result.Rows[0][0]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }  
}

<#
    Function to get current number and names of instances
#>
function get_instances() {
    # get instance startup time
    $result = (run_sql -Query 'SELECT instance_name
                                 FROM gv$instance
                                ORDER BY 
                                      instance_name')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        # generate string of instances names
        foreach ($row in $result) {
            $instances_names += ($row[0] + ';')
        }

        return (@{number = $result.Rows.Count; names = $instances_names} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Function to list database tablespaces, used by discovery
#>
function list_tablespaces() {
    # get list of tablespaces
    $result = (run_sql -Query "SELECT tablespace_name 
                                 FROM dba_tablespaces 
                                WHERE contents = 'PERMANENT'")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
        $list.Add(@{'{#TABLESPACE_NAME}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)
} 

<#
    Function to list ASM diskgroups, used by discovery
#>
function list_asm_diskgroups() {
    # get list of ASM diskgroups
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

    return (@{data = $list} | ConvertTo-Json -Compress)
}

<#
    Function to list guarantee restore points, used by discovery
#>
function list_guarantee_restore_points() {
    # get list of guarantee restore points
    $result = (run_sql -Query "SELECT name 
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

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
        $list.Add(@{'{#RESTORE_POINT_NAME}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)
}

<#
    Function to get data for guarantee restore points
#>
function get_guarantee_restore_points_data() {
    # get information about current status of guarantee restore points
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
        return '{}'
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{date = $row[1]; used_bytes = $row[2]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
    Function to get state of ASM diskgroups in the database
#>
function get_asm_diskgroups_state() {
    # get state of ASM diskgroups
    $result = (run_sql -Query 'SELECT name 
                                    , state
                                 FROM v$asm_diskgroup')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no asm diskgroups - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return '{}'
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{state = $row[1]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
    Function to get data for asm diskgroups (used_pct, used_bytes, max etc.)
#>
function get_asm_diskgroups_data() {
    # get space utilization in ASM disk groups
    $result = (run_sql -Query 'SELECT name
                                    , (total_mb - free_mb) * 1024 * 1024 used_bytes
                                    , round((total_mb - free_mb)/total_mb * 100, 4) used_pct
                                    , total_mb * 1024 * 1024 total_bytes
                                 FROM v$asm_diskgroup')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no ASM diskgroups - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return '{}'
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{used_bytes = $row[1]; used_pct = $row[2]; total = $row[3]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
    Function to list pluggable databases
#>
function list_pdbs() {
    # check if instance is available and represents container database
    if (-Not (is_available_and_cdb)) {
        return "{`n`t`"data`":[`n`t]`n}"
    }

    $result = (run_sql -Query "SELECT name 
                                 FROM v`$pdbs 
                                WHERE name != 'PDB`$SEED'")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no PDBs - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{`n`t`"data`": [`n`t]`n}"
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
        $list.Add(@{'{#PDB_NAME}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)
}

<#
    Function to list standby destinations, used by discovery
#>
function list_standby_databases() {
    # get list of standby destinations
    $result = (run_sql -Query "SELECT destination
                                 FROM v`$archive_dest
                                WHERE target = 'STANDBY'")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no standby databases - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{`n`t`"data`": [`n`t]`n}"
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
        $list.Add(@{'{#STANDBY_DEST}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)
}

<#
    Function to get data about standby destinations
#>
function get_standby_data() {
    # get current status of standby destinations
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
        return '{}'
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{status = $row[1]; valid_now = $row[2]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
    Function to get instance status, OPEN stands for OK, any other results are equalent to FAIL
#>
function get_pdb_state() {
    # check if instance is available and represents container database
    if (-Not (is_available_and_cdb)) {
        # there are no PDB databases in this instance
        return "{}"
    }

    $result = (run_sql -Query "SELECT name
                                    , open_mode 
                                 FROM v`$pdbs 
                                WHERE name not in ('PDB`$SEED')")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{state = $row[1]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
    Function to provide list of tablespaces in pluggable databases
#>
function list_pdbs_tablespaces() {
    # check if instance is available and represents container database
    if (-Not (is_available_and_cdb)) {
        # there are no PDB databases in this instance
        return "{`"data`": []}"
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
        return '{}'
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
        $list.Add(@{'{#PDB_NAME}' = $row[0]; '{#TABLESPACE_NAME}' = $row[1]})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)
}

<#
    Function to provide used space for tablespaces (excluding tablespaces of pluggable databases)
    Checks/Triggers for individual tablespaces are done by dependant items
#>
function get_tbs_space_data() {
    # get space utilizatoin for tablespaces (not pdb)
<#
    # The query bellow cannot be used if there are tablespaces defined as not ASSM (user). In future it should be reviewed again
    $result = (run_sql -Query "SELECT d.tablespace_name 
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

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{used_pct = $row[1]; used_bytes = $row[2]; max_bytes = $row[3]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
    Function to provide used space for tablespaces of pluggable databases, excluding tablespaces in root container
    Checks/Triggers for individual tablespaces are done by dependant items
#>
function get_pdbs_tbs_used_space() {
    # check if instance is available and represents container database
    if (-Not (is_available_and_cdb)) {
        # there are no PDB databases in this instance
        return '{}'
    }

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
        return '{}'
    }

    $dict = @{}
    $pdb = ''

    foreach ($row in $result) {
        
        if ($pdb -ne $row[0]) {
            $pdb = $row[0]
            $dict.Add($pdb, @{})
        }

        $dict.$pdb.Add($row[1], @{used_pct = $row[2]; used_bytes = $row[3]; max_bytes = $row[4]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
    Function to provide state for tablespaces (excluding tablespaces of pluggable databases)
    Checks/Triggers for individual tablespaces are done by dependant items
    Time in backup mode in hours
#>
function get_tbs_state() {
    # get current state for all tablespaces
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
                                    , (SELECT round((sysdate - nvl(min(b.time), sysdate)) * 24, 4)
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

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{state = $row[1]; backup_mode = $row[2]; backup_mode_hours_since = $row[3]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
    Function to provide state for tablespaces of pluggable databases, excluding tablespaces in root container
    Checks/Triggers for individual tablespaces are done by dependant items
#>
function get_pdbs_tbs_state() {
    # check if instance is available and represents container database
    if (-Not (is_available_and_cdb)) {
        # there are no PDB databases in this instance
        return '{}'
    }

    # get status for all pdb' tablespaces
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
                                    , (SELECT round((sysdate - nvl(min(b.time), sysdate)) * 24, 4)
                                         FROM v`$backup b
                                            , dba_data_files d
                                        WHERE d.tablespace_name  = t.tablespace_name
                                          AND d.file_id = b.file#
                                          AND b.status = 'ACTIVE') hours_since
                                 FROM cdb_tablespaces t
                                    , v`$pdbs p
                                WHERE t.contents = 'PERMANENT'
                                  AND t.con_id = p.con_id
                                ORDER BY
                                      p.name"
              )

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no PDB - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return '{}'
    }

    $dict = @{}
    $pdb = ''

    foreach ($row in $result) {
        
        if ($pdb -ne $row[0]) {
            $pdb = $row[0]
            $dict.Add($pdb, @{})
        }

        $dict.$pdb.Add($row[1], @{state = $row[2]; backup_mode = $row[3]; backup_mode_hours_since = $row[4]})
    }

    return ($dict | ConvertTo-Json -Compress)
} 

<#
    Function to provide percentage of current processes to maximum available
#>
function get_processes_data() {
    # get current utilization of database processes
    $result = (run_sql -Query "SELECT max(value) max_processes
                                    , count(p.pid) current_processes
                                    , trunc((count(p.pid) / max(v.value)) * 100, 2) pct_used
                                 FROM (SELECT value 
                                         FROM v`$parameter 
                                        WHERE name = 'processes') v  
                                    , v`$process p")

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{max = $result.Rows[0][0]; current = $result.Rows[0][1]; pct = $result.Rows[0][2]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Function to provide used FRA space
#>
function get_fra_data() {
    # get FRA utlilization
    $result = (run_sql -Query 'SELECT trunc((space_used - space_reclaimable) / space_limit * 100, 4) used_pct
                                    , space_used used_bytes
                                    , space_limit fra_size
                                 FROM v$recovery_file_dest')
    
    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{used_pct = $result.Rows[0][0]; used_bytes = $result.Rows[0][1]; fra_size = $result.Rows[0][2]} | ConvertTo-Json -Compress)
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
    # get information about last successfull backup
    $result = (run_sql -Query "SELECT to_char(nvl(s.end_time, d.created), 'DD/MM/YYYY HH24:MI:SS') backup_date
                                    , round((sysdate - nvl(s.end_time, d.created)) * 24, 4) hours_since
                                 FROM (SELECT max(end_time) end_time
                                         FROM v`$rman_status
                                        WHERE object_type in ('DB FULL', 'DB INCR')
                                          AND status like 'COMPLETED%') s
                                    , (SELECT created FROM v`$database) d" `
                       -CommandTimeout 30
                )

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{date = $result.Rows[0][0]; hours_since = $result.Rows[0][1]} | ConvertTo-Json -Compress)
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
    # get information about last successfull archive log backup
    # TODO: add check for archive mode
    $result = (run_sql -Query "SELECT to_char(nvl(s.end_time, d.created), 'DD/MM/YYYY HH24:MI:SS') backup_date
                                    , round((sysdate - nvl(s.end_time, d.created)) * 24, 4) hours_since
                                 FROM (SELECT max(end_time) end_time
                                         FROM v`$rman_status
                                        WHERE object_type = 'ARCHIVELOG'
                                          AND status like 'COMPLETED%') s
                                    , (SELECT created FROM v`$database) d"  `
                       -CommandTimeout 25
                )

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return ( @{date = $result.Rows[0][0]; hours_since = $result.Rows[0][1]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Function to get data about users who have privilegies above normal (DBA, SYSDBA)
#>
function get_elevated_users_data() {
    # get users with DBA and SYSDBA privilegies
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
        return '{}'
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

<#
    Function to provide number of detected corrupted blocks
    Corrupted block detected automaticaly by RMAN, so this function should work in conjunction with backup policy
#>
function get_block_corruption_number() {
    # get FRA utlilization
    $result = (run_sql -Query 'SELECT count(*)
                                 FROM v$database_block_corruption')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{number = $result.Rows[0][0]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }    
}

# execute required check
&$CheckType