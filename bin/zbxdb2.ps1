﻿#!/bin/pwsh

<#
    Created: 16/11/2018

    Parameters to modify in zabbix agent configuration file:
    # it will allow \ symbol to be used as part of InstanceName variable
    UnsafeUserParameters=1 
    
    UserParameter provided as part of oracle.conf file which has to be places in zabbix_agentd.d directory

    Create user for monitoring 
#>

Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,        # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Hostname,         # Host name
    [Parameter(Mandatory=$true, Position=3)][int]$Port = 50000,        # Port number if required
    [Parameter(Mandatory=$true, Position=4)][string]$Username = '',    # User name
    [Parameter(Mandatory=$true, Position=5)][string]$Password = '',    # Password
    [Parameter(Mandatory=$true, Position=6)][string]$Database = ''     # Database name
    )

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)

Import-Module -Name "$RootPath\lib\Library-StringCrypto.psm1"

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

    # Decrypy password
    If ($Password) {
        $DBPassword = Read-EncryptedString -InputString $Password -Password (Get-Content "$RootPath\etc\.pwkey")
    }
 
    # Column symbol after variable name raises error
    $db2ConnectionString = "Database=$Database;User ID=$Username;Password=$DBPassword;Server=$Hostname`:$Port; Connect Timeout = $ConnectTimeout;"

    $factory = [System.Data.Common.DbProviderFactories]::GetFactory(“IBM.Data.DB2”)
   
    $db2Connection = $factory.CreateConnection()
    $db2Connection.ConnectionString = $db2ConnectionString
    
    # try to open connection
    try {
        [void]$db2Connection.Open()
    } 
    catch {
        write-Host $_
        return 'ERROR: CONNECTION REFUSED'
    }

    $dbcmd = $factory.CreateCommand()
    $dbcmd.Connection = $db2Connection
    $dbcmd.CommandText = $Query
    $dbcmd.CommandType = [System.Data.CommandType]::Text
    $dbcmd.CommandTimeout = $CommandTimeout

    $da = $factory.CreateDataAdapter()
    $da.SelectCommand = $dbcmd

    $dataTable = New-Object System.Data.DataTable
    try {
        [void]$da.Fill($dataTable)
        $result = $dataTable
    }
    catch {
        # TODO: better handling and logging for invalid statements
        # DEBUG: To print error
        Write-Host "$_"
        $result = 'ERROR: QUERY TIMED OUT'
    } 
    finally {
        $db2Connection.Close()
    }

    # Comma in front is essential as without it return provides object's value, not object itselt
    return ,$result
}

<#
Function to check database availability
#>
function get_database_state() {
    
    $result = (run_sql -Query 'SELECT count(*) FROM syscat.tablespaces')

    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -gt 0) {
        return 'OK'
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }
    else {
        return 'ERROR: UNKNOWN'
    }
}

function get_version() {
    
    $result = (run_sql -Query "SELECT service_level FROM table(sysproc.env_get_inst_info())")

    # SELECT service_level FROM table(sysproc.env_get_prod_info()
    # SELECT service_level FROM table(sysproc.env_get_sys_info()

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

function list_tablespaces() {

    $result = (run_sql -Query "SELECT tbsp_name 
                                 FROM sysibmadm.tbsp_utilization  
								WHERE tbsp_type='DMS'") 

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

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

<#
Function to provide state for tablespaces (excluding tablespaces of pluggable databases)
Checks/Triggers for individual tablespaces are done by dependant items
#>
function get_tbs_state(){

    $result = (run_sql -Query "SELECT tbsp_name
                                    , tbsp_state 
                                 FROM sysibmadm.tbsp_utilization  
								WHERE tbsp_type='DMS'")

    if ($result.GetType() -eq [System.String]) {
        # Instance is not available
        return $result
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

function list_hadr() {

    $result = (run_sql -Query "SELECT hadr_remote_host
                                 FROM sysibmadm.snaphadr
								WHERE tbsp_type='DMS'") 

    if ($result.GetType() -eq [System.String]) {
        # Instance is not available
        return $null
    }

    $idx = 0
    $json = "{ `n`t`"data`": [`n"

    # generate JSON
    foreach ($row in $result) {
        $json += "`t`t{`"{#HADR_HOST}`": `"" + $row[0] + "`"}"
        $idx++

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}

function get_tbs_used_space() {

    $result = (run_sql -Query "SELECT '<tr><td>' || ru.tbsp_name || '</td>'
													   || '<td>' || dbu.tbsp_state || '</td>'
													   || '<td>' || ru.tbsp_type || ' (max ' || char(int(ru.real_max_size)) || 'GB) </td>'
													   || CASE
															  WHEN dec(dec(dbu.tbsp_total_size_kb)/1024/1024/dec(ru.real_max_size)*100) > $criticalThreshold 
																  THEN '<td class=''error''>' || char(decimal(decimal(dbu.tbsp_total_size_kb)/1024/1024/decimal(ru.real_max_size)*100, 31, 2))
															  WHEN dec(dec(dbu.tbsp_total_size_kb)/1024/1024/dec(ru.real_max_size)*100) > $warningThreshold 
																  THEN '<td class=''warning''>' || char(dec(dec(dbu.tbsp_total_size_kb)/1024/1024/dec(ru.real_max_size)*100, 31, 2)) 
															  ELSE
																  '<td class=''ok''>' || char(quantize(dec(dbu.tbsp_total_size_kb)/1024/1024/dec(ru.real_max_size)*100, decfloat(0.01)))
															  END
													   ||'</td>'
													   || '<td>' || char(quantize(dec(dbu.tbsp_used_size_kb)/1024/1024, decfloat(0.01)))
													   || '<td>' || char(quantize(dec(dbu.tbsp_total_size_kb)/1024/1024, decfloat(0.01)))
													   || '</td></tr>'
													 FROM 
														( SELECT tbsp_id 
															   , char(tbsp_name,20) as tbsp_name 
															   , CASE tbsp_content_type 
																	 WHEN 'ANY' THEN 'REGULAR' 
																 ELSE tbsp_content_type 
																 END as tbsp_type 
															   , CASE tbsp_max_size 
																	 WHEN -1 THEN CASE tbsp_content_type 
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
																	 dec(tbsp_max_size)/1024/1024/1024
																 END as real_max_size 
															FROM sysibmadm.tbsp_utilization  
														   WHERE tbsp_type='DMS' 
														) as ru  
														, sysibmadm.tbsp_utilization as dbu 
													WHERE ru.tbsp_id = dbu.tbsp_id") 

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

        if ($idx -lt $result.Rows.Count) {
            $json += ','
        }
        $json += "`n"
    }

    $json += "`t]`n}"

    return $json
}


<#
Function to get instance startup timestamp
#>
function get_startup_time() {
    
    $result = (run_sql -Query "SELECT to_char(db2start_time,'dd/mm/yyyy hh24:mi:ss') FROM sysibmadm.snapdbm")

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
Function to provide amount of connected applications
#>
function get_appls_amount() {
    $result = (run_sql -Query ('SELECT count(*) FROM sysibmadm.applications'))

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
Function to provide percentage of utilized logs
#>
function get_appls_utilization_pct() {
    # TODO: check if maxappls set to -1
    $result = (run_sql -Query ("SELECT ROUND((c.cnt/p.value)*100,2)
                                  FROM (SELECT value FROM sysibmadm.dbcfg WHERE name = 'maxappls') p
                                     , (SELECT count(*) cnt FROM sysibmadm.applications) c"))

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
Function to provide percentage of utilized logs
#>
function get_logs_utilization_pct() {
    $result = (run_sql -Query ('SELECT log_utilization_percent FROM sysibmadm.log_utilization'))

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
Function to provide time of last succeseful backup
#>
function get_last_db_backup() {
    $result = (run_sql -Query ("SELECT TIMESTAMP_FORMAT(end_time,'DD/MM/YYYY HH24:MI:SS')
					              FROM SYSIBMADM.DB_HISTORY 
							     WHERE OPERATION='B' 
								   AND TIMESTAMP_FORMAT(end_time,'YYYYMMDDHH24MISS') > CURRENT TIMESTAMP - 1 DAYS 
								   AND SQLCODE IS NOT NULL"))

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