<#
.SYNOPSIS
    Script for password encryption

.DESCRIPTION
    Output of this script is used as {$PASSWORD} macro on Zabbix Server side
    It has been done for prevention of storing passwords in plain text form

.PARAMETER InputString
    This parameter provides string which has to be encrypted

.NOTES
    Version:        1.0
    Author:         Eugene Bobkov
    Creation Date:  xx/02/2019
    
    $RootPath\etc\.pwkey has to be populated and readable

.EXAMPLE
    PS> powershell -NoLogo -NoProfile -NonInteractive -executionPolicy Bypass -File D:\DBA\zbxpwsh\bin\pwgen.ps1 -CheckType kdjfUEns#ed
    sfrifjdserefewo4iw4lfwk2o3in2re=
#>

param (
    [Parameter(Mandatory=$true, Position=1)][string]$InputString        # Password to encrypt
)

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)

# Load encryption module
Import-Module -Name "$RootPath\lib\Library-StringCrypto.psm1"

# Encrypt string
Write-EncryptedString -InputString $InputString -Password (Get-Content "$RootPath\etc\.pwkey")