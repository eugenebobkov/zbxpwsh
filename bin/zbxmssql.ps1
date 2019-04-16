#!/bsin/pwsh

<#
.SYNOPSIS
    Monitoring script for Microsoft SQL Server(MSSQL), intended to be executed by Zabbix Agent

.DESCRIPTION
    Connects to MSSQL using build-in .NET libraries, no any additional installation required
    UserParameter provided in mssql.conf file which can be found in $global:RootPath\zabbix_agentd.d directory

.PARAMETER CheckType
    This parameter provides name of function which is required to be executed

.PARAMETER Hostname
    Hostname or IP adress of the server where required MSSQL instance is running

.PARAMETER Service
    Instance name (eg SQL001)

.PARAMETER Port
    TCP port, normally 1403

.PARAMETER Username
    This parameter is not mandatory and domain user should be used in conjunction with Integrated Security
    MSSQL user is required when Integrated Security cannot be used

.PARAMETER Password
    Encrypted password for MSSQL user. Encrypted string can be generated with $global:RootPath\bin\pwgen.ps1

.NOTES
    Version:        1.0
    Author:         Eugene Bobkov
    Creation Date:  02/03/2018
 
.EXAMPLE
    powershell -NoLogo -NoProfile -NonInteractive -executionPolicy Bypass -File D:\DBA\zbxpwsh\bin\zbxmssql.ps1 -CheckType get_instance_state -Hostname mssql_server -Port 1403
#>

param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,      # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,       # Hostname
    [Parameter(Mandatory=$true, Position=3)][string]$Service,        # Service name like SQL001
    [Parameter(Mandatory=$true, Position=4)][int]$Port,              # Port number
    [Parameter(Mandatory=$false, Position=5)][string]$Username = '', # User name, required for SQL server authentication
    [Parameter(Mandatory=$false, Position=6)][string]$Password = ''  # Password, required for SQL server authentication
)

$global:RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$global:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Definition

Import-Module -Name "$global:RootPath\lib\Library-Common.psm1"
Import-Module -Name "$global:RootPath\lib\Library-StringCrypto.psm1"

<#
.SYNOPSIS
    Internal function to connect to an instance and execute required sql statement 

.PARAMETER Query
    SQL statment to run

.PARAMETER ConnectTimeout
    How long to wait for instance to accept connection

.PARAMETER CommandTimeout
    How long sql statement will be running, if it runs longer - it will be terminated

.OUTPUTS
    [System.Data.DataTable] or [System.String]

.NOTES
    In normal circumstances the functions returns query result as [System.Data.DataTable]
    If connection cannot be established or query returns error - returns error as [System.String]
#>
function run_sql() {
    param (
        [Parameter(Mandatory=$true)][string]$Query,
        # Sum of $ConnectTimeout and $CommandTimeout must not be more than 30, as 30 is maximum timeout allowed for Zabbix agent (4.0) before its connection timed out by server
        [Parameter(Mandatory=$false)][int32]$ConnectTimeout = 5,      # Connect timeout, how long to wait for instance to accept connection
        [Parameter(Mandatory=$false)][int32]$CommandTimeout = 10      # Command timeout, how long sql statement will be running, if it runs longer - it will be terminated
    )

    # Construct serverInstance connection string
    if ($Service -ne 'MSSQLSERVER') {
        $serverInstance = $Hostname + "\$Service,$Port"
    } 
    else {
        $serverInstance = $Hostname + ",$Port"
    }
               
    if ($Username -eq '') {
        $connectionString = "Server = $serverInstance; Database = master; Integrated Security=true;"
    } else {
        # Decrypt password
        if ($Password -ne '') {
            $dbPassword = Read-EncryptedString -InputString $Password -Password (Get-Content "$global:RootPath\etc\.pwkey")
        } else {
            $dbPassword = ''
        }
        $connectionString = "Server = $serverInstance; database = master; Integrated Security=false; User ID = $Username; Password = $dbPassword;"
    }

    # How long scripts attempts to connect to instance
    # default is 15 seconds and it will cause saturation issues for Zabbix agent (too many checks) 
    $connectionString += "Connect Timeout = $ConnectTimeout;"

    # Create the connection object
    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString

    # Try to open connection
    try {
        [void]$connection.Open()
    } 
    catch {
        # report error, sanitize it to remove IPs if there are any
        $e = $_.Exception.Message.Split(':',2)[1].Trim() -Replace ("(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", "xxx.xxx.xxx.xxx")
        Write-Log -Message ('[' + $Hostname + ':' + $CheckType + '] ' + $e)
        return "ERROR: CONNECTION REFUSED: $e"
    }

    # Build the SQL command
    $command = New-Object System.Data.SqlClient.SqlCommand $Query
    $command.Connection = $connection
    # If query running for more then specified parameter - it will be terminated and error code posted
    $command.CommandTimeout = $CommandTimeout

    # Prepare command execution
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
    $dataTable = New-Object System.Data.DataTable

    # The following command opens connection and executes required statement
    try {
         # [void] simitair to | Out-Null, prevents posting output of Fill function (number of rows returned), which will be picked up as function output
         [void]$adapter.Fill($dataTable)
         $result = $dataTable
    } 
    catch {
        # report error, sanitize it to remove IPs if there are any
        $e = $_.Exception.Message.Split(':',2)[1].Trim() -Replace ("(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", "xxx.xxx.xxx.xxx")
        Write-Log -Message ('[' + $Hostname + ':' + $CheckType + '] ' + $e)
        $result = "ERROR: QUERY FAILED: $e"
    } 
    finally {
        [void]$connection.Close()
    }

    # Comma in front is essential as without it result is provided as object's value, not object itself
    return ,$result
}

<#
.SYNOPSIS
    Function to return instance status, ONLINE stands for OK, any other results is equalent to FAIL
#>
function get_instance_state() {
    $result = (run_sql -Query 'SELECT max(1) 
                                 FROM sys.databases 
                                WHERE 1=1')
    
    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {
        return 'ONLINE'
    }
    else {
        return $result
    }     
}

<#
.SYNOPSYS
    Function to return status of Agent

.NOTES
    RUNNING or STOPPED
#>
function get_agent_state() {
    $result = (run_sql -Query "IF EXISTS (
                                    SELECT 1
                                      FROM master.dbo.sysprocesses
                                     WHERE program_name = N'SQLAgent - Generic Refresher'
                               )
                                   BEGIN
                                       SELECT 'RUNNING' AS 'SQLServerAgent Status'
                                   END
                               ELSE
                                   BEGIN
                                       SELECT 'STOPPED' AS 'SQLServerAgent Status'
                                   END"
              )

    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{state = $result.Rows[0][0]} | ConvertTo-Json -Compress)
    } 
    else {
        # Error
        return $result
    } 
}

<#
.SYNOPSYS
    Function to return software version
#>
function get_version() {
    $result = (run_sql -Query "SELECT CONCAT(CONVERT(VARCHAR, SERVERPROPERTY('ProductVersion')), ' ', 
                                      CONVERT(VARCHAR, SERVERPROPERTY('Edition')), ' ', 
                                      CONVERT(VARCHAR, SERVERPROPERTY('ProductLevel')))
                              "
              )

    if ($result.GetType() -eq [System.Data.DataTable]) {
        # Result
        return (@{version = $result.Rows[0][0]} | ConvertTo-Json -Compress)
    } 
    else {
        # data is not in [System.Data.DataTable] format
        return $result
    }
}

<#
.SYNOPSYS
    Function to provide time of instance startup
#>
function get_instance_data() {
    # applicable for 2008 and higher
    $result = (run_sql -Query 'SELECT CONVERT(CHAR(19), sqlserver_start_time, 120) startup_time
                                    , @@SERVERNAME
                                 FROM sys.dm_os_sys_info')

    # TODO: add check for versions below 2008 if required for some reason
    if ($result.GetType() -eq [System.Data.DataTable]) {
        # Results
        return (@{startup_time = $result.Rows[0][0]; host_name = $result.Rows[0][1]} | ConvertTo-Json -Compress)
    } 
    else {
        return $result
    }
}

<#
.SYNOPSYS
    This function provides list of database in JSON format
#>
function list_databases() {

    $result = (run_sql -Query 'SELECT name 
                                 FROM sys.databases')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
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
    Returns current status for all databases
#>
function get_databases_state() {
<#
 0 - ONLINE
 1 - RESTORING
 2 - RECOVERING
 3 - RECOVERY PENDING
 4 - SUSPECT
 5 - EMERGENCY
 6 - OFFLINE
 7 - Database Does Not Exist on Server
#>

    $result = (run_sql -Query "SELECT name
                                    , CASE state
                                          WHEN 0 THEN 'ONLINE'
                                          WHEN 1 THEN 'RESTORING'
                                          WHEN 2 THEN 'RECOVERING'
                                          WHEN 3 THEN 'RECOVERY PENDING'
                                          WHEN 4 THEN 'SUSPECT'
                                          WHEN 5 THEN 'EMERGENCY'
                                          WHEN 6 THEN 'OFFLINE'
                                          WHEN 7 THEN 'DOES NOT EXIST'
                                      ELSE 'UNKNOWN'
                                      END 
                                 FROM sys.databases")

    ### TODO: AOAG check
    # if ($output -ne 'ONLINE') {
    #     # check sys.dm_hadr_database_replica_states for AOAG status for this database
    #     $output = (run_sql -Query ("SELECT s.database_state 
    #                                   FROM sys.databases d
    #                                      , sys.dm_hadr_database_replica_states s
    #                                  WHERE d.name = '" + $Database + "'
    #                                    and s.database_id = d.database_id") `
    #                        -Instance $Instance
    #               )
    # }
    ### 

    ### TODO: Microsoft Cluster check
    # get-cluster
    # get-clusterresource
    # get-clusternode
    # get-clustergroup
    ### sys.dm_os_cluster_nodes
    
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
.SYNOPSYS
    Returns number of sessions for each database
#>
function get_databases_connections() {

   $result = (run_sql -Query 'SELECT name
                                   , count(status)
                                FROM sys.databases sd
                                     LEFT JOIN master.dbo.sysprocesses sp ON sd.database_id = sp.dbid
                               GROUP BY name'
             )
    
    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{connections = $row[1]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
.SYNOPSYS
    Returns size for all databases

.NOTES
    STUB, not implemented yet, no template
#>
function get_databases_size() {

   $result = (run_sql -Query 'SELECT name
                                   , count(status)
                                FROM sys.databases sd
                                     LEFT JOIN master.dbo.sysprocesses sp ON sd.database_id = sp.dbid
                               GROUP BY name'
             )
    
    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{connections = $row[1]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
.SYNOPSYS
    This function provides list of filegroups in the database, exempt tempdb
#>
function list_filegroups() {

    $result = (run_sql -Query "CREATE TABLE #fgInfo (
                                 databaseName varchar(512)
                               , fileGroupName varchar(512)
                               )
                               
                               DECLARE @sql varchar(1000)
                               
                               SET @sql = 'USE [?];
                                           INSERT #fgInfo (databaseName, fileGroupName)
                                           SELECT DISTINCT
                                                  DB_NAME()
                                                , f.name fileGroupName
                                             FROM dbo.sysfiles s
                                                , sys.filegroups f
                                            WHERE s.groupid = f.data_space_id -- logs do not exist in filegroups
                                              -- it is not required to discover tempdb and it does not need triggers
                                              AND DB_NAME() <> ''tempdb'';' 

                               EXEC sp_MSforEachDB @sql

                               SELECT databaseName
                                    , fileGroupName
                                 FROM #fgInfo;

                               DROP TABLE #fgInfo;")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
        $list.Add(@{'{#DB_NAME}' = $row[0]; '{#FG_NAME}' = $row[1]})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)
}

<#
.SYNOPSYS
    This function returns data for space allocation in filegroups (including tempdb)
#>
function get_filegroups_data() {

    $result = (run_sql -Query "CREATE TABLE #spaceInfo (
                                    fileName varchar(512)
                                  , current_size bigint
                                  , used_space bigint
                                  , fileGroupName varchar(512)
                               )

                               DECLARE @sql varchar(1000)

                               set @sql = 'Use [?];
                                            INSERT #spaceInfo (fileName, current_size, used_space, fileGroupName) 
                                            SELECT s.fileName
                                                 , CAST(size AS bigint) as current_size
                                                 , CAST(fileproperty(s.name, ''SpaceUsed'') AS bigint) as used_space
                                                 , f.name as fileGroupName
                                              FROM dbo.sysfiles s
                                                 , sys.filegroups f
                                             WHERE s.groupid = f.data_space_id;'

                               EXEC sp_MSforeachdb @sql

                               SELECT DB_NAME(database_id)
                                    , si.fileGroupName
                                    , sum(cast(si.current_size as bigint) * 8192) current_bytes
                                    , sum(si.used_space * 8192) as used_bytes
                                    , sum(CASE 
                                              WHEN mf.max_size = -1 THEN 17592186044416 -- Maximum size for a datafile is 16T as per documentation
                                              ELSE cast(mf.max_size as bigint) * 8192
                                          END) as max_bytes
                                    , ROUND( sum(cast(used_space * 8192 as float))/sum(cast(CASE 
                                                                                                WHEN mf.max_size = -1 THEN 17592186044416 -- Maximum size for a datafile is 16T as per documentation
                                                                                                ELSE cast(mf.max_size as float) * 8192
                                                                                            END as float
                                                                                           )
                                                                                      ) * 100
                                           , 4) as used_pct
                                 FROM #spaceInfo si
                                      LEFT OUTER JOIN sys.master_files AS mf 
                                      ON mf.physical_name = si.fileName
                                GROUP BY 
                                      DB_NAME(database_id)
                                    , si.fileGroupName
                                ORDER BY 
                                      DB_NAME(database_id); -- order by  is required to avoid problem with duplicate keys when adding elements to the dictionary
                                                            -- current logic expects ordered sequence od databases to check equallity with previous element

                                DROP TABLE #spaceInfo;
                              ")
    
    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $dict = @{}
    $db = ''

    foreach ($row in $result) {
        # Check if new element has to be added to DB dictionary
        if ($db -ne $row[0]) {
            $db = $row[0]
            # Add next element to DB dictionary   
            $dict.Add($db, @{})
        }

        # Add tablespace
        $dict.$db.Add($row[1], @{current_bytes = $row[2]; used_bytes = $row[3]; max_bytes = $row[4]; used_percent = $row[5]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
.SYNOPSYS
    This function provides list of transaction files in the databases, excluding tempdb
#>
function list_transaction_logs() {
    # get list of databases in the instance, except tempdb
    $result = (run_sql -Query "SELECT name 
                                 FROM sys.databases
                                WHERE name <> 'tempdb'
                               ")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
        $list.Add(@{'{#DB_NAME}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)
}

<#
.SYNOPSYS
    This function returns data for space allocation in filegroups
#>
function get_transaction_logs_data() {

    $result = (run_sql -Query "CREATE TABLE #spaceInfo (
                                    fileName varchar(512)
                                  , current_size bigint
                                  , used_space bigint
                               )

                               DECLARE @sql varchar(1000)

                               set @sql = 'Use [?];
                                            INSERT #spaceInfo (fileName, current_size, used_space) 
                                            SELECT fileName
                                                 , CAST(size AS bigint)
                                                 , CAST(fileproperty(name, ''SpaceUsed'') AS bigint)
                                              FROM dbo.sysfiles
                                             WHERE groupid = 0;'

                               EXEC sp_MSforeachdb @sql

                               SELECT DB_NAME(database_id)
                                    , sum(cast(si.current_size as bigint) * 8192) current_bytes
                                    , sum(si.used_space * 8192) as used_bytes
                                    , sum(CASE 
                                              WHEN mf.max_size = -1 THEN 2199023255552 -- Maximum size for a log file is 2T as per documentation
                                              ELSE cast(mf.max_size as bigint) * 8192
                                          END) as max_bytes
                                    , ROUND( sum(cast(used_space * 8192 as float))/sum(cast(CASE 
                                                                                                WHEN mf.max_size = -1 THEN 2199023255552 -- Maximum size for a log file is 2T as per documentation
                                                                                                ELSE cast(mf.max_size as float) * 8192
                                                                                            END as float
                                                                                           )
                                                                                      ) * 100
                                           , 4) as used_pct
                                 FROM #spaceInfo si
                                      LEFT OUTER JOIN sys.master_files AS mf 
                                      ON mf.physical_name = si.fileName
                                GROUP BY 
                                      DB_NAME(database_id)
                                ORDER BY
                                      DB_NAME(database_id);

                                DROP TABLE #spaceInfo;
                              ")
    
    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $dict = @{}

    foreach ($row in $result) {
        # Add tablespace
        $dict.Add($row[0], @{current_bytes = $row[1]; used_bytes = $row[2]; max_bytes = $row[3]; used_percent = $row[4]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
.SYNOPSYS
    Returns number of waits for each database
#>
function get_databases_waits() {

   $result = (run_sql -Query "SELECT
	                                 sd.name
                                   , CASE 
		                                 WHEN A.NumBlocking > 0 THEN A.NumBlocking
                                     ELSE 
                                         0
	                                 END AS numblocking
                                FROM sys.databases sd
                                     LEFT JOIN (
                                                 SELECT
		                                                R.database_id
                                                      , count(*) as NumBlocking
	                                               FROM sys.dm_os_waiting_tasks WT
	                                                    INNER JOIN sys.dm_exec_sessions S ON WT.session_id = S.session_id
	                                                    INNER JOIN sys.dm_exec_requests R ON R.session_id = WT.session_id
	                                                    LEFT JOIN sys.dm_exec_requests RBlocker ON RBlocker.session_id = WT.blocking_session_id
	                                              WHERE R.status = 'suspended' -- Waiting on a resource
		                                            AND S.is_user_process = 1 -- Is a used process
                                                    AND R.session_id <> @@spid -- Filter out this session
		                                            AND WT.wait_type Not Like '%sleep%' -- more waits to ignore
		                                            AND WT.wait_type Not Like '%queue%' -- more waits to ignore
		                                            AND WT.wait_type Not Like -- more waits to ignore
			                                        CASE 
                                                        WHEN SERVERPROPERTY('IsHadrEnabled') = 0 THEN 'HADR%'
			                                            ELSE 'zzzz' 
                                                    END
		                                            AND WT.wait_type not in (
                                                                              'CLR_SEMAPHORE',
                                                                              'SQLTRACE_BUFFER_FLUSH',
                                                                              'WAITFOR',
                                                                              'REQUEST_FOR_DEADLOCK_SEARCH',
                                                                              'XE_TIMER_EVENT',
                                                                              'BROKER_TO_FLUSH',
                                                                              'BROKER_TASK_STOP',
                                                                              'CLR_MANUAL_EVENT',
                                                                              'CLR_AUTO_EVENT',
                                                                              'FT_IFTS_SCHEDULER_IDLE_WAIT',
                                                                              'XE_DISPATCHER_WAIT',
                                                                              'XE_DISPATCHER_JOIN',
                                                                              'BROKER_RECEIVE_WAITFOR'
                                                                            )
	                                              GROUP BY R.database_id
                                               ) A ON A.database_id = sd.database_id"
             )
    
    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    
    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{waits = $row[1]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
.SYNOPSYS
    Returns date of the last database backup and hours since for each database
#>
function get_databases_backup() {
   # if backup hasn't been ever done - it will return create date for the database
   $result = (run_sql -Query "SELECT sdb.name
                                   , sdb.recovery_model_desc
                                   , CASE 
                                         WHEN sdb.name = 'tempdb' THEN 'NOT APPLICABLE'
                                         WHEN sys.fn_hadr_backup_is_preferred_replica(sdb.name) = 0 THEN 'AOAG REPLICA'
                                     ELSE
                                         CONVERT(CHAR(19), COALESCE(MAX(bus.backup_finish_date), max(sdb.create_date)), 120) 
                                     END AS last_date
                                   , CASE 
                                         WHEN sdb.name = 'tempdb' OR sys.fn_hadr_backup_is_preferred_replica(sdb.name) = 0 THEN 0
                                     ELSE
                                         ROUND(CAST(DATEDIFF(second, COALESCE(MAX(bus.backup_finish_date), max(sdb.create_date)), GETDATE()) AS FLOAT)/60/60, 4)
                                     END AS hours_since 
                                FROM master.sys.databases sdb
                                     LEFT OUTER JOIN msdb.dbo.backupset bus 
                                     ON bus.database_name = sdb.name
                                     AND bus.type = 'D'
                               GROUP BY 
                                     sdb.Name
                                   , sdb.recovery_model_desc"
             )

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{recovery_model = $row[1]; date = $row[2]; hours_since = $row[3]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
.SYNOPSYS
    Returns hource since the least recent database backup

.NOTES
    It will be used for one trigger per instance instead of multiple trigger per database
    This approach allows to avoid flood of incidents, if we have faulure of backup system
#>
function get_max_hours_since_db_backup() {
   # if backup hasn't been ever done - it will return create date for the database
   $result = (run_sql -Query "SELECT min(hours_since) hours_since 
                                FROM (SELECT ROUND(CAST(DATEDIFF(second, COALESCE(max(bus.backup_finish_date), max(sdb.create_date)), GETDATE()) AS FLOAT)/60/60, 4) hours_since 
                                        FROM master.sys.databases sdb
                                             LEFT OUTER JOIN msdb.dbo.backupset bus 
                                             ON bus.database_name = sdb.name
                                             AND bus.type = 'D'
                                       WHERE sdb.name <> 'tempdb'
                                         AND sys.fn_hadr_backup_is_preferred_replica(sdb.name) <> 0
                                       GROUP BY 
                                             sdb.Name
                                     ) tbl"
             )

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    return (@{max_hours_since = $result.Rows[0][0]} | ConvertTo-Json -Compress)
}

<#
.SYNOPSYS
    Returns date of last transaction log backup and hours since it for each database
#>
function get_databases_log_backup() {
   # if backup hasn't been ever done - it will return create date for the database
   $result = (run_sql -Query "SELECT sdb.name
                                   , sdb.recovery_model_desc
                                   , CASE 
                                         WHEN sdb.recovery_model_desc = 'SIMPLE' OR sdb.name = 'tempdb' THEN 'NOT APPLICABLE'
                                         WHEN sys.fn_hadr_backup_is_preferred_replica(sdb.name) = 0 THEN 'AOAG REPLICA'
                                     ELSE
                                         CONVERT(CHAR(19), COALESCE(MAX(bus.backup_finish_date), max(sdb.create_date)), 120) 
                                     END AS last_date
                                   , CASE 
		                                 WHEN sdb.recovery_model_desc = 'SIMPLE' OR sdb.name = 'tempdb' OR sys.fn_hadr_backup_is_preferred_replica(sdb.name) = 0 THEN 0
                                     ELSE                                      
                                         ROUND(CAST(DATEDIFF(second, COALESCE(MAX(bus.backup_finish_date), max(sdb.create_date)), GETDATE()) AS FLOAT)/60/60, 4) 
                                     END AS hours_since
                                FROM master.sys.databases sdb
                                     LEFT OUTER JOIN msdb.dbo.backupset bus
                                          ON bus.database_name = sdb.name
                                          AND bus.type = 'L'
                               GROUP BY 
                                     sdb.name
                                   , sdb.recovery_model_desc"
             )

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{recovery_model = $row[1]; date = $row[2]; hours_since = $row[3]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
.SYNOPSYS
    Returns hours since the least recent log backup

.NOTES
    It will be used for one trigger per instance instead of multiple trigger per database
    This approach allows to avoid flood of incidents, if we have faulure of backup system
#>
function get_max_hours_since_log_backup() {
   # if backup hasn't been ever done - it will return create date for the database
   $result = (run_sql -Query "SELECT min(hours_since)
                                FROM (SELECT ROUND(CAST(DATEDIFF(second, COALESCE(MAX(bus.backup_finish_date), max(sdb.create_date)), GETDATE()) AS FLOAT)/60/60, 4) hours_since
                                        FROM master.sys.databases sdb
                                             LEFT OUTER JOIN msdb.dbo.backupset bus
                                                  ON bus.database_name = sdb.name
                                                  AND bus.type = 'L'
                                       WHERE sdb.name <> 'tempdb'
                                         AND sdb.recovery_model_desc <> 'SIMPLE'
                                         AND sys.fn_hadr_backup_is_preferred_replica(sdb.name) <> 0
                                       GROUP BY 
                                             sdb.Name
                                     ) tbl"
             )

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    return (@{max_hours_since = $result.Rows[0][0]} | ConvertTo-Json -Compress)
}


<#
.SYNOPSYS
    Function to get data about users who have privilegies above normal (SYSADMIN)

.NOTES
    TODO: Rewrite with CovertTo-Json
#>
function get_elevated_users_data(){
    # get users with elevated privilegies
    $result = (run_sql -Query "SELECT sp.name
                                    , 'SYSADMIN'
                                    , sp.is_disabled
                                 FROM sys.server_role_members rm
                                    , sys.server_principals sp
                                WHERE rm.role_principal_id = SUSER_ID('Sysadmin')
                                  AND rm.member_principal_id = sp.principal_id")

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
        $json += "`t`t{`"" + $row[0] + "`":{`"privilege`":`"" + $row[1] + "`",`"disabled`":`"" + $row[2] + "`"}}"

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