<#
.SYNOPSIS
    Lager en Kerberos keytab for en AD-tjenestebruker (for SMB/CIFS-mount på Linux).

.DESCRIPTION
    Kjøres på en Windows-maskin med RSAT/AD-verktøy (typisk en DC eller
    management-server) som domeneadmin. Scriptet:
      1) Setter AES-krypteringstyper på brukeren
      2) (valgfritt) nullstiller passordet slik at AES-nøkler genereres
      3) Kjører ktpass og produserer .keytab-fila
      4) Skriver ut nøkkelinfo og neste steg

    Kopier deretter .keytab til Debian-serveren (WinSCP) og kjør:
        sudo ./setup.sh keytab /tmp/<bruker>.keytab

.PARAMETER SamAccountName
    AD-brukernavnet (sAMAccountName), f.eks. SVC-User.

.PARAMETER Realm
    Kerberos-realm i STORE bokstaver, f.eks. AD.EXAMPLE.COM.

.PARAMETER NetbiosDomain
    NetBIOS-domenenavn, f.eks. EXAMPLE.

.PARAMETER OutFile
    Sti til keytab-fila som skal lages.

.PARAMETER ResetPassword
    Hvis satt, blir du bedt om nytt passord (kreves for at AES-nøkler skal
    genereres første gang du bytter krypteringstype).

.EXAMPLE
    .\New-SmbKeytab.ps1 -SamAccountName SVC-User `
        -Realm AD.EXAMPLE.COM -NetbiosDomain EXAMPLE `
        -OutFile C:\temp\svc-user.keytab -ResetPassword
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SamAccountName,
    [Parameter(Mandatory)] [string] $Realm,
    [Parameter(Mandatory)] [string] $NetbiosDomain,
    [string] $OutFile = "C:\temp\$($SamAccountName.ToLower()).keytab",
    [ValidateSet('AES256-SHA1','AES128-SHA1')] [string] $Crypto = 'AES256-SHA1',
    [switch] $ResetPassword
)

$ErrorActionPreference = 'Stop'

Import-Module ActiveDirectory

$principal = "$SamAccountName@$Realm"
$mapUser   = "$NetbiosDomain\$SamAccountName"

Write-Host "== Lager keytab for $principal ==" -ForegroundColor Cyan

# 1) Sett AES-krypteringstyper
Write-Host "[1/4] Setter KerberosEncryptionType = AES128,AES256 ..." -ForegroundColor Yellow
Set-ADUser -Identity $SamAccountName -KerberosEncryptionType AES128,AES256

# 2) Passord (kreves for AES-nøkkelgenerering ved bytte av krypteringstype)
$plain = $null
if ($ResetPassword) {
    $sec1 = Read-Host "Nytt passord for $SamAccountName" -AsSecureString
    $sec2 = Read-Host "Bekreft passord" -AsSecureString
    $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec1))
    $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec2))
    if ($p1 -ne $p2) { throw "Passordene er ikke like." }
    $plain = $p1
    Write-Host "[2/4] Setter nytt passord ..." -ForegroundColor Yellow
    Set-ADAccountPassword -Identity $SamAccountName -Reset `
        -NewPassword (ConvertTo-SecureString $plain -AsPlainText -Force)
} else {
    $sec = Read-Host "Eksisterende passord for $SamAccountName (samme som i AD)" -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    Write-Host "[2/4] Bruker eksisterende passord (ingen reset)." -ForegroundColor Yellow
}

# 3) ktpass -> keytab
$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

Write-Host "[3/4] Kjører ktpass -> $OutFile ..." -ForegroundColor Yellow
& ktpass /out $OutFile `
    /princ $principal `
    /mapuser $mapUser `
    /crypto $Crypto `
    /ptype KRB5_NT_PRINCIPAL `
    /pass $plain
if ($LASTEXITCODE -ne 0) { throw "ktpass feilet (exit $LASTEXITCODE)." }

# Forklar forventet SPN-advarsel fra ktpass
Write-Host ""
Write-Host "MERK: Hvis ktpass skrev en advarsel om 'Unable to set SPN mapping data'" -ForegroundColor DarkGray
Write-Host "      (feilkode 0x13 / servicePrincipalName), er dette forventet stoy." -ForegroundColor DarkGray
Write-Host "      SMB/CIFS-mount via keytab trenger ingen SPN-mapping - keytab-en" -ForegroundColor DarkGray
Write-Host "      ble likevel laget korrekt (se 'Key created' over)." -ForegroundColor DarkGray

# Rydd opp passord fra minnet (best effort)
$plain = $null; [GC]::Collect()

# 4) Vis status
Write-Host "[4/4] Ferdig. Brukerinfo:" -ForegroundColor Yellow
Get-ADUser $SamAccountName -Properties KerberosEncryptionType,ServicePrincipalName |
    Select-Object Name,KerberosEncryptionType,ServicePrincipalName | Format-List

Write-Host ""
Write-Host "Keytab laget: $OutFile" -ForegroundColor Green
Write-Host "Neste steg:" -ForegroundColor Cyan
Write-Host "  1) Kopier $OutFile til Debian-serveren (WinSCP)."
Write-Host "  2) sudo ./setup.sh keytab /tmp/$(Split-Path -Leaf $OutFile)"
Write-Host ""
Write-Host "MERK: Hver gang du roterer passordet til $SamAccountName må du lage ny keytab." -ForegroundColor DarkYellow
