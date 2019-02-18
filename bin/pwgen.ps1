Param (
    [Parameter(Mandatory=$true, Position=1)][string]$InputString        # Password to encrypt
)

$RootPath = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)

Import-Module -Name "$RootPath\lib\Library-StringCrypto.psm1"

Write-EncryptedString -InputString $InputString -Password (Get-Content "$RootPath\etc\.pwkey")