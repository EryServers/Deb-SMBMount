
<#
.SYNOPSIS
    Get the SSH host key fingerprint from a remote machine.
.DESCRIPTION
    Connects to a remote host using WinSCP and retrieves the SSH host key
    fingerprint. Useful when setting up Backup-SSH.ps1 for a new machine.
.PARAMETER HostName
    Hostname or IP address of the remote machine.
.PARAMETER Algorithm
    Fingerprint algorithm to use. Default: SHA-256.
    Valid values: SHA-256, MD5.
.EXAMPLE
    .\Get-SshHostKeyFingerprint.ps1 -HostName "server01.domain.local"
.EXAMPLE
    .\Get-SshHostKeyFingerprint.ps1 -HostName "192.168.1.50" -Algorithm MD5
.NOTES
    Author: Eryniox
    Date:   May 2026
.LINK
    https://github.com/EryServers/
#>

#requires -Modules WinSCP

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$HostName,

    [Parameter(Mandatory = $false, Position = 1)]
    [ValidateSet("SHA-256", "MD5")]
    [string]$Algorithm = "SHA-256"
)

Import-Module WinSCP

$sessionOption = New-WinSCPSessionOption -HostName $HostName
$fingerprint = Get-WinSCPHostKeyFingerprint -SessionOption $sessionOption -Algorithm $Algorithm

Write-Host "Host:        $HostName"
Write-Host "Algorithm:   $Algorithm"
Write-Host "Fingerprint: $fingerprint"
Write-Host ""
Write-Host "Use this value for -SshHostKeyFingerprint in Backup-SSH.ps1"

return $fingerprint
