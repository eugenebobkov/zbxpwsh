###Zabbix templates and Powershell scripts for database monitoring 

**Purpose:**

This configuration (scripts and templates) was created for multidomain environment with limited resources, where central Zabbix Server(s) located in Management Domain only and managed(databases) hosts accessible by using Windows based management hosts in each domain. Scripted schecks are run by agent installed on each management host and each check connects to a database (or WMI for OS Windows checks) remotely, based on parameters provided to the script. 

Firewall configuration required only for communication between Zabbix server and its agents on management hosts as Zabbix agents are installed only on Management hosts.

Scripts' aliaces in templates based on UserParameter, see .conf files in ${ZBXPWSH_ROOT}/zabbix_agentd.conf.d

**Implementation:**

Modules are written in PowerShell and expected to be run on Windows, but partially they were tested on Linux as well

Linux OS checks are running shell commands using SSH agent directly from Zabbix server 

**Templates:**

*RDBMS monitoring:*

- MS SQL Server (zbx_templates/zbxmssql.xml, module zbxmssql.ps1, ADO.NET)
- Oracle Database (zbx_templates/zbxoracle.xml, module zbxoracle.ps1, ADO.NET)
- IBM DB2 LUW Database (zbx_templates/zbxdb2.xml, module zbxdb2.ps1, ADO.NET)
- PostgreSQL (zbx_templates/zbxpgsql.xml, module zbxpgsql.ps1, psql as connection agent
  
  TODO: Npgsql not implemented yet https://www.npgsql.org)

*OS Monitoring (mainly database related check, CPU/System load, memory consumption and filesystems' usage)*
- Linux (zbx_templates/zbx_db_linux.xml, no modules required, Zabbix SSH Agent, each host expected to have user with public key populated.
  
  TODO: If PowerShell based checks will be required and checks has to be done from Windows Management hosts - it will be, probably, done by using ```plink```)
- Windows (zbx_templates/zbx_db_windows.xml, module zbxdbwin.ps1, WMI remote calls)

Please check Wiki for installation procedure  
