#!/bin/pwsh

<#
    Created: 16/11/2018

    Parameters to modify in zabbix agent configuration file:
    # it will allow \ symbol to be used as part of InstanceName variable
    UnsafeUserParameters=1 
    
    UserParameter provided as part of db2.conf file which has to be places in zabbix_agentd.d directory

    Create user for monitoring 
#>

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,        # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,         # Host name
    [Parameter(Mandatory=$true, Position=3)][string]$Service,          # Database name
    [Parameter(Mandatory=$true, Position=4)][int]$Port = 50000,        # Port number, default is 50000
    [Parameter(Mandatory=$true, Position=5)][string]$Username,         # User name
    [Parameter(Mandatory=$true, Position=6)][string]$Password          # Password
)

$global:RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$global:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Definition

Import-Module -Name "$global:RootPath\lib\Library-Common.psm1"
Import-Module -Name "$global:RootPath\lib\Library-StringCrypto.psm1"

<#
   OS statistics:
      v$ostat
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

    # Decrypy password
    # As for 11.1 DB2 client doesn't support Integrated Security (https://www.ibm.com/support/knowledgecenter/en/SSEPGG_11.1.0/com.ibm.swg.im.dbclient.adonet.ref.doc/doc/DB2ConnectionClassConnectionStringProperty.html)
    if ($Password -ne '' ) {
        $dbPassword = Read-EncryptedString -InputString $Password -Password (Get-Content "$global:RootPath\etc\.pwkey")
    } else {
        $dbPassword = ''
    }
 
    # Column symbol after variable name raises error
    $connectionString = "Database = $Service; User ID = $Username; Password = $dbPassword; Server = $Hostname`:$Port; Connect Timeout = $ConnectTimeout;"

    $factory = [System.Data.Common.DbProviderFactories]::GetFactory(“IBM.Data.DB2”)
   
    $connection = $factory.CreateConnection()
    $connection.ConnectionString = $connectionString
    
    # try to open connection
    try {
        [void]$connection.Open()
    } 
    catch {
        # report error, sanitize it to remove IPs if there are any
        $error = $_.Exception.Message.Split(':',2)[1].Trim() -Replace ("(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})", "xxx.xxx.xxx.xxx")
        Write-Log -Message ('[' + $Hostname + ':' + $CheckType + '] ' + $error)
        return "ERROR: CONNECTION REFUSED: $error"
    }

    $command = $factory.CreateCommand()
    $command.Connection = $connection
    $command.CommandText = $Query
    $command.CommandType = [System.Data.CommandType]::Text
    $command.CommandTimeout = $CommandTimeout

    $da = $factory.CreateDataAdapter()
    $da.SelectCommand = $command

    $dataTable = New-Object System.Data.DataTable
    try {
        [void]$da.Fill($dataTable)
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
    Function to check database availability
#>
function get_database_state() {
    # get database response, fact of recieving data itself can be considered as good sign of the database availability
    $result = (run_sql -Query 'SELECT ibmreqd 
                                 FROM sysibm.sysdummy1')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 'Y') {
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
    # get software version
    $result = (run_sql -Query 'SELECT service_level version 
                                 FROM table(sysproc.env_get_inst_info())')

    # SELECT service_level FROM table(sysproc.env_get_prod_info()
    # SELECT service_level FROM table(sysproc.env_get_sys_info()

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{version = $result.Rows[0][0]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }    
}

<#
    Function to get overall database size
#>
function get_database_size() {
    # get software version
    $result = (run_sql -Query 'SELECT sum(DATA_OBJECT_P_SIZE + INDEX_OBJECT_P_SIZE + LONG_OBJECT_P_SIZE + LOB_OBJECT_P_SIZE + XML_OBJECT_P_SIZE) 
                                 FROM sysibmadm.admintabinfo')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{database_size = $result.Rows[0][0]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }    
}

<#
    Function to provide list of all DMS tablespaces, used by discovery
#>
function list_tablespaces() {
    # get list of all DMS tablespaces
    $result = (run_sql -Query "SELECT tbsp_name 
                                 FROM sysibmadm.tbsp_utilization  
								WHERE tbsp_type='DMS'") 

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no DMS tablespaces - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return "{`n`t`"data`": [`n`t]`n}"
    }

    $list = New-Object System.Collections.Generic.List[System.Object]

    foreach ($row in $result) {
        $list.Add(@{'{#TABLESPACE_NAME}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)
}

<#
    Function to provide state for tablespaces (DMS only)
    Checks/Triggers for individual tablespaces are done by dependant items
#>
function get_tbs_state(){
    # get state for all DMS tablespaces
    $result = (run_sql -Query "SELECT tbsp_name
                                    , tbsp_state 
                                 FROM sysibmadm.tbsp_utilization  
								WHERE tbsp_type='DMS'")

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no DMS tablespaces - return empty JSON
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
    Function to provide all HADR destinations
#>
function list_hadr_hosts() {

    $result = (run_sql -Query 'SELECT hadr_remote_host
                                 FROM sysibmadm.snaphadr') 

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
        $list.Add(@{'{#HADR_HOST}' = $row[0]})
    }

    return (@{data = $list} | ConvertTo-Json -Compress)
}

<#
    Function to provide status and state of HADR destinations
#>
function get_hadr_data(){

    $result = (run_sql -Query 'SELECT hadr_remote_host
                                    , hadr_connect_status
                                    , hadr_state
                                 FROM sysibmadm.snaphadr')

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
        $dict.Add($row[0], @{state = $row[1]; connect_status = $row[2]})
    }

    return ($dict | ConvertTo-Json -Compress)
}

<#
    Function to provide information about tablespaces' utilization
#>
function get_tbs_used_space() {
    # get information about used space in all tablespaces, DMS only
    $result = (run_sql -Query "SELECT ru.tbsp_name
                                    , ru.real_max_size * 1024 * 1024 * 1024 max_bytes
                                    , QUANTIZE(dbu.tbsp_used_size_kb/(ru.real_max_size * 1024 * 1024) * 100, decfloat(0.0001)) used_pct
                                    , dbu.tbsp_used_size_kb * 1024 used_bytes
                                 FROM 
									( SELECT tbsp_id 
										   , tbsp_name as tbsp_name 
										   , CASE tbsp_content_type 
												 WHEN 'ANY' THEN 'REGULAR' 
													 ELSE tbsp_content_type 
												 END as tbsp_type 
										   , CASE tbsp_max_size 
                                             WHEN -1 
                                                  THEN CASE tbsp_content_type 
                                                       WHEN 'ANY' 
                                                            THEN CASE tbsp_page_size 
                                                                 WHEN 4096 THEN 64
                                                                 WHEN 8192 THEN 128
                                                                 WHEN 16384 THEN 256   
                                                                 WHEN 32768 THEN 512   
                                                            ELSE  
                                                                -1 
                                                            END
                                                       WHEN 'LARGE' 
                                                       THEN CASE tbsp_page_size 
                                                                 WHEN 4096 THEN 8192
                                                                 WHEN 8192 THEN 16384   
                                                                 WHEN 16384 THEN 32768   
                                                                 WHEN 32768 THEN 65536   
                                                            ELSE  
                                                                -1 
                                                            END 
                                                  ELSE 
													  -1
												  END
											 ELSE
												 dec(tbsp_max_size)
											 END as real_max_size 
                                        FROM sysibmadm.tbsp_utilization  
                                       WHERE tbsp_type='DMS' 
                                    ) as ru  
                                    , sysibmadm.tbsp_utilization as dbu 
                                WHERE ru.tbsp_id = dbu.tbsp_id") 

    if ($result.GetType() -ne [System.Data.DataTable]) {
        # Instance is not available
        return $result
    }
    # if there are no DMS tablespaces - return empty JSON
    elseif ($result.Rows.Count -eq 0) {
        return '{}'
    }

    $dict = @{}

    foreach ($row in $result) {
        $dict.Add($row[0], @{max_bytes = $row[1]; used_pct = $row[2]; used_bytes = $row[3]})
    }

    return ($dict | ConvertTo-Json -Compress)
}


<#
    Function to get instance startup timestamp
#>
function get_instance_data() {
    # get startup time
    $result = (run_sql -Query "SELECT s.startup_time 
                                    , e.host_name
                                 FROM (select to_char(db2start_time,'dd/mm/yyyy hh24:mi:ss') startup_time from sysibmadm.snapdbm) s
                                    , (select host_name from sysibmadm.env_sys_info) e")

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        return (@{startup_time = $result.Rows[0][0]; host_name = $result.Rows[0][1]} | ConvertTo-Json -Compress)
    }
    else {
        return $result
    } 
}


<#
    Function to provide percentage of utilized applications
#>
function get_appls_data() {
    # get data about current applications' utilization
    # TODO: check if maxappls set to -1
    $result = (run_sql -Query "SELECT p.value max_appls
                                    , c.cnt current_appls
                                    , QUANTIZE((c.cnt/p.value)*100, decfloat(0.0001)) pct_used
                                 FROM (SELECT cast(cast(value as int) as float) value FROM sysibmadm.dbcfg WHERE name = 'maxappls') p
                                    , (SELECT cast(count(*) as float) cnt FROM sysibmadm.applications) c"
              )

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        # Return datata in JSON format
        return ( @{
                     max = $result.Rows[0][0]
                     current = $result.Rows[0][1]
                     pct = $result.Rows[0][2]
                 } | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Function to provide percentage of utilized logs
#>
function get_logs_utilization_data() {
    # get data about current log utilization
    $result = (run_sql -Query ('SELECT log_utilization_percent used_pct
                                      , total_log_used_kb * 1024 used_bytes
                                      , total_log_available_kb * 1024 total
                                  FROM sysibmadm.log_utilization'
                              )
              )

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        # Return datata in JSON format
        return ( @{
                     used_pct = $result.Rows[0][0]
                     used_bytes = $result.Rows[0][1]
                     total = $result.Rows[0][2]
                 } | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Function to provide time of last successeful database backup
#>
function get_last_db_backup() {
    # get date and hours since the last successfull backup
    $result = (run_sql -Query "SELECT to_char(timestamp_format(max(end_time), 'yyyymmddhh24miss'), 'DD/MM/YYYY HH24:MI:SS') backup_date
                                    , trunc(cast(timestampdiff(4, CURRENT TIMESTAMP - TIMESTAMP_FORMAT(max(end_time), 'YYYYMMDDHH24MISS')) as float)/60, 4) hours_since
					             FROM sysibmadm.db_history
							    WHERE operation = 'B' 
							   AND sqlcode IS NULL"  `
                       -CommandTimeout 25
                )

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        # Return datata in JSON format
        return ( @{
                     date = $result.Rows[0][0]
                     hours_since = $result.Rows[0][1]
                 } | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Function to provide time of last succeseful archived log backup
#>
function get_last_log_backup() {
    # Check log archive mode of the database 
    $result = (run_sql -Query "SELECT value 
                                 FROM sysibmadm.dbcfg 
                                WHERE name = 'logarchmeth1'")

    # Check if data in expected format has been recieved
    # If database has no archival mode enabled or it's in LOGRETAIN mode - this check is not applicable
    if ($result.GetType() -eq [System.Data.DataTable]) {
        if ($result.Rows[0][0] -eq 'LOGRETAIN' -or $result.Rows[0][0] -eq '') {
            return (@{date = 'NOT APPLICABLE'; hours_since = 0} | ConvertTo-Json -Compress)
        } 
    }
    else {
        return $result
    }

    # The database has archival process enabled
    $result = (run_sql -Query "SELECT to_char(timestamp_format(max(end_time), 'yyyymmddhh24miss'), 'DD/MM/YYYY HH24:MI:SS') backup_date
                                    , trunc(cast(timestampdiff(4, CURRENT TIMESTAMP - TIMESTAMP_FORMAT(max(end_time), 'YYYYMMDDHH24MISS')) as float)/60, 4) hours_since
					             FROM sysibmadm.db_history
							    WHERE operation = 'X' 
							      AND sqlcode IS NULL"  `
                       -CommandTimeout 25
                )

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable]) {
        # Return datata in JSON format
        return ( @{
                     date = $result.Rows[0][0]
                     hours_since = $result.Rows[0][1]
                 } | ConvertTo-Json -Compress)
    }
    else {
        return $result
    }
}

<#
    Function to get data about users who have privilegies above normal (DBADM)
#>
function get_elevated_users_data(){
    # get users with dbadm priviligies
    $result = (run_sql -Query "SELECT grantee
                                    , 'DBADM'
                                 FROM syscat.dbauth
                                WHERE dbadmauth = 'Y'")

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
        $json += "`t`t{`"" + $row[0] + "`":{`"privilege`":`"" + $row[1] + "`"}}"

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