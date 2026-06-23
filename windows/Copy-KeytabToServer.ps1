<#
.SYNOPSIS
    Laster opp en keytab-fil til en Linux/Debian-server via SFTP (WinSCP-modulen).

.DESCRIPTION
    Enkel hjelper for å kopiere en .keytab (eller hvilken som helst fil) til
    serveren før du kjører `sudo ./setup.sh keytab /tmp/<fil>`.
    Bruker PowerShell-modulen WinSCP – samme som Backup-SSH.ps1 i PS-Backup.

    Autentisering:
      * Oppgi -PrivateKeyPath for nøkkel-basert pålogging, ELLER
      * la stå tom for å bli bedt om passord (Get-Credential).

.PARAMETER Server
    Hostnavn eller IP til Debian-serveren.

.PARAMETER Username
    SSH-bruker (en bruker med skrivetilgang til -RemotePath, typisk din admin-bruker).

.PARAMETER KeytabPath
    Lokal sti til keytab-fila som skal lastes opp.

.PARAMETER RemotePath
    Mappe på serveren filen legges i. Standard: /tmp/

.PARAMETER SshHostKeyFingerprint
    SSH host-key fingerprint, f.eks. "ssh-ed25519 256 xx:xx:...". Anbefalt.

.PARAMETER PrivateKeyPath
    Valgfri sti til privat nøkkel (.ppk). Brukes i stedet for passord.

.PARAMETER TrustAnyHostKey
    Hopp over verifisering av host-key (kun for førstegangs-oppsett – mindre sikkert).

.EXAMPLE
    .\Copy-KeytabToServer.ps1 -Server debian-server.ad.example.com `
        -Username svc-admin -KeytabPath C:\temp\svc-user.keytab `
        -SshHostKeyFingerprint "ssh-ed25519 256 xx:xx:..."

.NOTES
    Krever: Install-Module WinSCP
#>
#requires -Modules WinSCP
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Server,
    [Parameter(Mandatory)] [string] $Username,
    [Parameter(Mandatory)] [string] $KeytabPath,
    [string] $RemotePath = "/tmp/",
    [string] $SshHostKeyFingerprint,
    [string] $PrivateKeyPath,
    [switch] $TrustAnyHostKey
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -Path $KeytabPath -PathType Leaf)) {
    throw "Finner ikke keytab-fila: $KeytabPath"
}
if (-not $SshHostKeyFingerprint -and -not $TrustAnyHostKey) {
    throw "Oppgi -SshHostKeyFingerprint, eller -TrustAnyHostKey for førstegangs-oppsett."
}

Import-Module WinSCP

# Bygg session-options
$optParams = @{
    HostName = $Server
    Protocol = 'Sftp'
}
if ($SshHostKeyFingerprint) {
    $optParams.SshHostKeyFingerprint = $SshHostKeyFingerprint
} elseif ($TrustAnyHostKey) {
    Write-Warning "TrustAnyHostKey er på – host-key blir IKKE verifisert."
    $optParams.GiveUpSecurityAndAcceptAnySshHostKey = $true
}

if ($PrivateKeyPath) {
    if (-not (Test-Path -Path $PrivateKeyPath -PathType Leaf)) {
        throw "Finner ikke privat nøkkel: $PrivateKeyPath"
    }
    $optParams.SshPrivateKeyPath = $PrivateKeyPath
    # Brukernavn må fortsatt oppgis via Credential (tomt passord ved nøkkel-auth)
    $optParams.Credential = New-Object System.Management.Automation.PSCredential(
        $Username, (New-Object System.Security.SecureString))
} else {
    $optParams.Credential = Get-Credential -UserName $Username `
        -Message "Passord for $Username@$Server"
}

$opt = New-WinSCPSessionOption @optParams

Write-Host "Kobler til $Server ..." -ForegroundColor Cyan
$session = New-WinSCPSession -SessionOption $opt
try {
    Send-WinSCPItem -WinSCPSession $session -Path $KeytabPath -Destination $RemotePath | Out-Null
    $remoteFile = ($RemotePath.TrimEnd('/')) + '/' + (Split-Path -Leaf $KeytabPath)
    Write-Host "Lastet opp: $remoteFile" -ForegroundColor Green
    Write-Host ""
    Write-Host "Neste steg på serveren:" -ForegroundColor Cyan
    Write-Host "  sudo ./setup.sh keytab $remoteFile"
}
finally {
    Remove-WinSCPSession -WinSCPSession $session
}
