#!/bin/pwsh

<#
    Created: 02/03/2018

    Parameters to modify in zabbix agent configuration file:
    # it will allow \ symbol to be used as part of InstanceName variable
    UnsafeUserParameters=1 
    
    UserParameter provided as part of mssql.conf file which has to be places in zabbix_agentd.d directory

    Create MSSQL user which will be used for monitoring
#>


Param (
    [Parameter(Mandatory=$true, Position=1)][string]$CheckType,      # Name of check function
    [Parameter(Mandatory=$true, Position=2)][string]$Instance,       # Instance name, required for instance related checks, <SERVERNAME>\<INSTANCE>
    [Parameter(Mandatory=$false, Position=3)][int]$Port = 1433,      # Port number, if required for non standart configuration, by default 1433
    [Parameter(Mandatory=$false, Position=4)][string]$Username = '', # User name, required for SQL server authentication
    [Parameter(Mandatory=$false, Position=5)][string]$Password = '', # Password, required for SQL server authentication
    [Parameter(Mandatory=$false, Position=6)][string]$Database = ''  # Database name, required for database related checks
    )

<#
Internal function to run provided sql statement. If for some reason it cannot be executed - it returns SQL EXECUTION FAILED
#>
function run_sql() {
#    [OutputType([System.Data.DataTable])]
    param (
        [Parameter(Mandatory=$true)][string]$Query,
        [Parameter(Mandatory=$false)][int32]$ConnectTimeout = 5,      # Connect timeout, how long to wait for instance to accept connection
        [Parameter(Mandatory=$false)][int32]$CommandTimeout = 5      # Command timeout, how long sql statement will be running, if it runs longer - it will be terminated
    )
    
    # DEBUG: Error in SQL execution will not terminate whole script and error output will be suppressed
    # $ErrorActionPreference = 'silentlycontinue'

    # This if block was created for situation when the script is used for local instances (not currently requireds)
    if ($Instance -eq 'MSSQLSERVER') {
        $serverInstance = '.\'
    } elseif (! $Instance -match '.*\\.*') {
        # $Instance doesn't contain \ symbol
        $serverInstance = ('.\' + $Instance)
    } else {
        $serverInstance = $Instance
    }

    # add Port to connection string
    $serverInstance += [string]",$Port"
           
    if ($Username -eq '') {
        $sqlConnectionString = "Server = $serverInstance; Database = master; Integrated Security=true;"
    } else {
        $sqlConnectionString = "Server = $serverInstance; database = master; Integrated Security=false; User ID = $Username; Password = $Password;"
    }

    # Create the connection object
    $sqlConnection = New-Object System.Data.SqlClient.SqlConnection $sqlConnectionString

    # How long scripts attempts to connect to instance
    # default is 15 seconds and it will cause saturation issues for Zabbix agent (too many checks) 
    $sqlConnection.ConnectionTimeout = $ConnectTimeout

    # TODO: try to open connection here
    try {
        [void]$sqlConnection.Open()
    } 
    catch {
        write-Host $_
        return 'ERROR: CONNECTION REFUSED'
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
        # TODO: better handling and logging for invalid statements
        # DEBUG: To print error
        Write-Host "$_"
        $result = 'ERROR: QUERY TIMED OUT'
    } 
    finally {
        $sqlConnection.Close()
    }

    # Comma in front is essential as without it return provides object's value, not object itselt
    return ,$result
}

<#
Function to check instance status, ONLINE stands for OK, any other results is equalent to FAIL
#>
function get_instance_state() {
    $result = (run_sql -Query 'SELECT max(1) FROM sys.databases WHERE 1=1')
    
    # Check if expected object has been recieved
    if ($result.GetType() -eq [System.Data.DataTable] -And $result.Rows[0][0] -eq 1) {
        return 'ONLINE'
    }
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }
}

<#
Function to check Agent status, 1 stands for OK, 0 stands for FAIL
#>
function get_agent_state() {
    #$result = (run_sql -Query "xp_servicecontrol 'querystate', 'SQLSERVERAGENT'")
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
                                   END")

    if ($result.GetType() -eq [System.Data.DataTable]) {
        return $result.Rows[0][0]
    } 
    elseif ($result.GetType() -eq [System.String]) {
        # Error
        return $result
    } 
}

<#
Function to provide MSSQL version
#>
function get_version() {
    $result = (run_sql -Query "SELECT CONCAT(CONVERT(VARCHAR, SERVERPROPERTY('ProductVersion')), ' ', 
                                      CONVERT(VARCHAR, SERVERPROPERTY('Edition')), ' ', 
                                      CONVERT(VARCHAR, SERVERPROPERTY('ProductLevel')))
                              "
              )

    if ($result.GetType() -eq [System.Data.DataTable]) {
        # Result
        return $result.Rows[0][0]
    } 
    elseif ($result.GetType() -eq [System.String]) {
        # Error
        return $result
    }
}

<#
Function to provide time of instance startup
#>
function get_startup_time() {
    # applicable for 2008 and higher
    $result = (run_sql -Query "SELECT sqlserver_start_time FROM sys.dm_os_sys_info")

    # TODO: add check for versions below 2008 if required for some reason
    if ($result.GetType() -eq [System.Data.DataTable]) {
        # Results
        return $result.Rows[0][0]
    } 
    elseif ($result.GetType() -eq [System.String]) {
        return $result
    }
}

<#
This function provides list of database in JSON format
#>
function list_databases() {

    $databases = (run_sql -Query "SELECT name FROM sys.databases")

    if ($databases.GetType() -eq [System.String]) {
        # Instance is not available
        return $null
    }

    $idx = 1
    $json = "{ `n`t`"data`": [`n"

    # generate JSON
    foreach ($row in $databases) {
        $json += "`t`t{`"{#DATABASE}`": `"" + $row[0] + "`"}"
       
        if ($idx -lt $databases.Rows.Count) {
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

    $result = (run_sql -Query ('SELECT name, state FROM sys.databases'))

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

    $idx = 1
    #$json = "{ `n`t`"data`": [`n"
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

    #$json += "`t]`n}"
    $json += "}"

    return $json
}

<#
Returns amount of sessions for all databases
#>
function get_databases_connections() {

   $result = (run_sql -Query ('SELECT name, count(status)
                                 FROM sys.databases sd
                                      LEFT JOIN master.dbo.sysprocesses sp ON sd.database_id = sp.dbid
                                GROUP BY name'))

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

# execute required check
&$CheckType
