Param (
    [Parameter(Mandatory=$true, Position=1)][string]$InputString        # Password to encrypt
)

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$global:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Definition

Import-Module -Name "$global:RootPath\lib\Library-StringCrypto.psm1"

Write-EncryptedString -InputString $InputString -Password (Get-Content "$global:RootPath\etc\.pwkey")