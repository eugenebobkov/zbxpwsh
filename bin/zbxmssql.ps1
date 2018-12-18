#!/bsin/pwshf

<#
    Created: 02/03/2018

    Parameters to modify in zabbix agent configuration file:
    # it will allow \ symbol to be used as part of InstanceName variable
    UnsafeUserParameters=1 
    
    UserParameter provided as part of mssql.conf file which has to be places in zabbix_agentd.d directory

    Create MSSQL user/domain user which will be used for monitoring
#>

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,      # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Instance,       # Instance name, required for instance related checks, <SERVERNAME>\<INSTANCE>
    [Parameter(Mandatory=$false, Position=3)][int]$Port = 1433,      # Port number, if required for non standart configuration, by default 1433
    [Parameter(Mandatory=$false, Position=4)][string]$Username = '', # User name, required for SQL server authentication
    [Parameter(Mandatory=$false, Position=5)][string]$Password = ''  # Password, required for SQL server authentication
    )

$global:RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$global:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Definition

Import-Module -Name "$global:RootPath\lib\Library-Common.psm1"
Import-Module -Name "$global:RootPath\lib\Library-StringCrypto.psm1"

<#
    Notes
#> 

<#
    Internal function to run provided sql statement. If for some reason it cannot be executed - it returns SQL EXECUTION FAILED
#>
function run_sql() {
#    [OutputType([System.Data.DataTable])]
    param (
        [Parameter(Mandatory=$true)][string]$Query,
        # Sum of $ConnectTimeout and $CommandTimeout must not be more than 30, as 30 is maximum timeout allowed for Zabbix agent befort its connection timed out by server
        [Parameter(Mandatory=$false)][int32]$ConnectTimeout = 5,      # Connect timeout, how long to wait for instance to accept connection
        [Parameter(Mandatory=$false)][int32]$CommandTimeout = 10      # Command timeout, how long sql statement will be running, if it runs longer - it will be terminated
    )

    # add Port to connection string
    $serverInstance = $Instance + ",$Port"
               
    if ($Username -eq '') {
        $sqlConnectionString = "Server = $serverInstance; Database = master; Integrated Security=true;"
    } else {
        If ("$Password") {
            $DBPassword = Read-EncryptedString -InputString $Password -Password (Get-Content "$global:RootPath\etc\.pwkey")
        }
        $sqlConnectionString = "Server = $serverInstance; database = master; Integrated Security=false; User ID = $Username; Password = $DBPassword;"
    }

    # How long scripts attempts to connect to instance
    # default is 15 seconds and it will cause saturation issues for Zabbix agent (too many checks) 
    $sqlConnectionString += "Connect Timeout = $ConnectTimeout;"

    # Create the connection object
    $sqlConnection = New-Object System.Data.SqlClient.SqlConnection $sqlConnectionString

    # TODO: try to open connection here
    try {
        [void]$sqlConnection.Open()
    } 
    catch {
        # report error, sanitize it to remove IPs if there are any
        $sqlError = $_.Exception.Message.Split(':',2)[1].Trim() -Replace ("(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", "xxx.xxx.xxx.xxx")
        Write-Log -Message $sqlError
        return "ERROR: CONNECTION REFUSED: $sqlError"
    }

    # Build the SQL command
    $sqlCommand = New-Object System.Data.SqlClient.SqlCommand $Query
    $sqlCommand.Connection = $sqlConnection
    # If query running for more then specified parameter - it will be terminated and error code posted
    $sqlCommand.CommandTimeout = $CommandTimeout

    # Prepare command execution
    $sqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter $sqlCommand
    $dataTable = New-Object System.Data.DataTable

    # The following command opens connection and executes required statement
    try {
         # [void] simitair to | Out-Null, prevents posting output of Fill function (amount of rows returned), which will be picked up as function output
         [void]$sqlAdapter.Fill($dataTable)
         $result = $dataTable
    } 
    catch {
        # report error, sanitize it to remove IPs if there are any
        $sqlError = $_.Exception.Message.Split(':',2)[1].Trim() -Replace ("(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", "xxx.xxx.xxx.xxx")
        Write-Log -Message $sqlError
        $result = "ERROR: QUERY FAILED: $sqlError"
    } 
    finally {
        [void]$sqlConnection.Close()
    }

    # Comma in front is essential as without it return provides object's value, not object itselt
    return ,$result
}

<#
    Function to check instance status, ONLINE stands for OK, any other results is equalent to FAIL
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
    Function to check Agent status, 1 stands for OK, 0 stands for FAIL
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
        return "{ `"data`": {`n`t `"state`":`"" + $result.Rows[0][0] + "`"`n`t}`n}"
    } 
    else {
        # Error
        return $result
    } 
}

<#
    Function to get software version
#>
function get_version() {
    $result = (run_sql -Query "SELECT CONCAT(CONVERT(VARCHAR, SERVERPROPERTY('ProductVersion')), ' ', 
                                      CONVERT(VARCHAR, SERVERPROPERTY('Edition')), ' ', 
                                      CONVERT(VARCHAR, SERVERPROPERTY('ProductLevel')))
                              "
              )

    if ($result.GetType() -eq [System.Data.DataTable]) {
        # Result
        return (@{version = $result.Rows[0][0]} | ConvertTo-Json)
    } 
    else {
        # data is not in [System.Data.DataTable] format
        return $result
    }
}

<#
    Function to provide time of instance startup
#>
function get_startup_time() {
    # applicable for 2008 and higher
    $result = (run_sql -Query 'SELECT CONVERT(CHAR(19), sqlserver_start_time, 120) 
                                 FROM sys.dm_os_sys_info')

    # TODO: add check for versions below 2008 if required for some reason
    if ($result.GetType() -eq [System.Data.DataTable]) {
        # Results
        return (@{startup_time = $result.Rows[0][0]} | ConvertTo-Json)
    } 
    else {
        return $result
    }
}

<#
    This function provides list of database in JSON format
#>
function list_databases() {

    $result = (run_sql -Query 'SELECT name 
                                 FROM sys.databases')

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $idx = 1
    $json = "{ `n`t`"data`": [`n"

    # generate JSON
    foreach ($row in $result) {
        $json += "`t`t{`"{#DATABASE}`": `"" + $row[0] + "`"}"
       
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
    Returns status for selected database
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

    $result = (run_sql -Query 'SELECT name
                                    , state 
                                 FROM sys.databases')

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

    $idx = 1
    $json = "{`n"

    # generate JSON
    foreach ($row in $result) {
        $json += "`t`t`"" + $row[0] + "`":`"" + $row[1] + "`""

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
    Returns amount of sessions for each database
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
    
    $idx = 1

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`t`"" + $row[0] + "`":`"" + $row[1] + "`""

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
    Returns amount of sessions for each database
#>
function get_databases_waits() {

   $result = (run_sql -Query "SELECT
	                                 sd.name
                                   , case 
		                                  when A.NumBlocking > 0 then A.NumBlocking
                                     else 0
	                                 end as numblocking
                                FROM sys.databases sd
                                     left join (
                                                 SELECT
		                                                R.database_id
                                                      , count(*) as NumBlocking
	                                               FROM sys.dm_os_waiting_tasks WT
	                                                    Inner Join sys.dm_exec_sessions S on WT.session_id = S.session_id
	                                                    Inner Join sys.dm_exec_requests R on R.session_id = WT.session_id
	                                                    Left Join sys.dm_exec_requests RBlocker on RBlocker.session_id = WT.blocking_session_id
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
                                               ) A on A.database_id = sd.database_id"
             )
    
    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    
    $idx = 1

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`t`"" + $row[0] + "`":`"" + $row[1] + "`""

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
    Returns date of last database backup and hours since it for each database
#>
function get_databases_backup() {
   # if backup hasn't been done - it will return create date for the database
   $result = (run_sql -Query 'SELECT sdb.name
                                   , COALESCE(CONVERT(CHAR(19), MAX(bus.backup_finish_date), 120), max(sdb.create_date)) AS last_date
                                   , ROUND(CAST(DATEDIFF(second, COALESCE(MAX(bus.backup_finish_date), max(sdb.create_date)), GETDATE()) AS FLOAT)/60/60, 4) hours_since
                                FROM master.sys.databases sdb
                                     LEFT OUTER JOIN msdb.dbo.backupset bus ON bus.database_name = sdb.name
                               GROUP BY 
                                     sdb.Name
                                   , sdb.recovery_model_desc'
             )

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $idx = 1

    # generate JSON
    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`"" + $row[0] + "`":{`"date`":`"" + $row[1] + "`",`"hours_since`":`"" + $row[2] + "`"}"

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
    Returns date of last transaction log backup and hours since it for each database
#>

function get_databases_log_backup() {
  
   # if backup hasn't been done - it will return create date for the database
   $result = (run_sql -Query "SELECT sdb.name
                                   , sdb.recovery_model_desc
                                   , COALESCE(CONVERT(CHAR(19), MAX(bus.backup_finish_date), 120), max(sdb.create_date)) AS last_date
                                   , ROUND(CAST(DATEDIFF(second, COALESCE(MAX(bus.backup_finish_date), max(sdb.create_date)), GETDATE()) AS FLOAT)/60/60, 4) hours_since
                                FROM master.sys.databases sdb
                                     LEFT OUTER JOIN msdb..backupset bus
                                          ON bus.database_name = sdb.name
                                          AND bus.type = 'L'
                               GROUP BY sdb.name, sdb.recovery_model_desc"
             )

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }

    $idx = 1

    # generate JSON

    $json = "{`n"

    foreach ($row in $result) {
        $json += "`t`"" + $row[0] + "`":{`"recovery_model`":`"" + $row[1] + "`",`"date`":`"" + $row[2] + "`",`"hours_since`":`"" + $row[3] + "`"}"

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
    Function to get data about users who have privilegies above normal (SYSADMIN)
#>
function get_elevated_users_data(){
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
