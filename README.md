# Deb-SMBMount

Verktøy for å sette opp **Kerberos-autentiserte CIFS/SMB-mounts** mot Active
Directory på **Debian 13** (og **Debian 12**) – konfig-drevet, slik at det er
raskt å rulle ut på flere servere med ulike brukere og shares.

Erstatter den manuelle prosessen i OneNote med én konfigfil og ett
`setup.sh`. NTLM-oppsettet fra Debian 12 
fungerer ikke lenger på Debian 13 – derfor Kerberos (`sec=krb5`). Kerberos
fungerer like godt på Debian 12, så du kan bruke samme verktøy til å
standardisere alle serverne på samme oppsett.

---

## Hva du får

| Komponent | Funksjon |
|-----------|----------|
| `config/smbmount.conf` | Én fil per server: bruker, prinsipp, keytab, shares |
| `setup.sh` | Installerer pakker, Kerberos-timer, fstab/automount, health-timer |
| `smb-kinit.sh` | Henter/fornyer TGT inn i tjenestebrukerens keyring |
| `smb-kerb-health.sh` | Sjekker TGT hver time, auto-recovery + e-postvarsel |
| `smb-kerb-status.sh` | Rask statusrapport (TGT, timere, mounts, logg) |
| `smb-fix-automounts.sh` | Nullstiller `mount-start-limit-hit` og re-trigger mounts |
| `windows/New-SmbKeytab.ps1` | Lager keytab på Windows/AD-siden |
| `windows/Copy-KeytabToServer.ps1` | Laster opp keytab til serveren via WinSCP |

Systemd-enheter navngis per instans (`smb-kinit-<bruker>`, `smb-health-<bruker>`),
så flere tjenestebrukere kan sameksistere på samme server.

---

## Forutsetninger

- Debian 13 **eller** Debian 12, med systemd.
- AD-tjenestebruker (f.eks. `SVC-User`) og en lokal Linux-bruker (f.eks. `plex`).
- Tilgang til en Windows-maskin med RSAT/`ktpass` for å lage keytab.

> **Bytter du en Debian 12-server fra NTLM til Kerberos:** verktøyet legger sin
> egen styrte blokk nederst i `/etc/fstab` og rører ikke dine gamle linjer.
> Kommenter ut / fjern de gamle `sec=ntlmssp`-mountlinjene for de samme
> mountpunktene først, så du unngår dobbelt-mount. Den gamle
> `credentials=`-fila trengs ikke lenger.

---

## Klon repoet

På Debian-serveren (grunn klone – kun siste commit, raskest):

```bash
git clone --depth 1 https://github.com/EryServers/Deb-SMBMount.git
cd Deb-SMBMount
chmod +x setup.sh scripts/*.sh
```

> Bytt ut URL-en med din egen fork om du har en. `--depth 1` henter bare
> nyeste versjon uten hele git-historikken.

---

## Steg 1 – Lag keytab på Windows (AD-siden)

Kjør på en DC/management-server som domeneadmin:

```powershell
.\windows\New-SmbKeytab.ps1 `
    -SamAccountName SVC-User `
    -Realm AD.EXAMPLE.COM `
    -NetbiosDomain EXAMPLE `
    -OutFile C:\temp\svc-user.keytab `
    -ResetPassword
```

Scriptet setter AES-krypteringstyper, (valgfritt) nytt passord, og kjører
`ktpass`. Kopiér `C:\temp\svc-user.keytab` til Debian-serveren (se
[Last opp keytab med WinSCP](#last-opp-keytab-med-winscp)), f.eks. til
`/tmp/svc-user.keytab`.

> Hver gang passordet til tjenestebrukeren roteres, må du lage **ny keytab**.

---

## Last opp keytab med WinSCP

Bruk hjelpescriptet (krever PowerShell-modulen `WinSCP`):

```powershell
.\windows\Copy-KeytabToServer.ps1 `
    -Server debian-server.ad.example.com `
    -Username svc-admin `
    -KeytabPath C:\temp\svc-user.keytab `
    -SshHostKeyFingerprint "ssh-ed25519 256 xx:xx:..."
```

Filen havner i `/tmp/` på serveren. Scriptet spør om passord (med mindre du
oppgir `-PrivateKeyPath`). Henter du fingeravtrykket første gang, kan du midlertidig
bruke `-TrustAnyHostKey` (mindre sikkert – fingeravtrykk anbefales).

Vil du heller bruke WinSCP-modulen direkte i et par linjer:

```powershell
Import-Module WinSCP
$opt = New-WinSCPSessionOption -HostName debian-server.ad.example.com `
    -Protocol Sftp -Credential (Get-Credential) `
    -SshHostKeyFingerprint "ssh-ed25519 256 xx:xx:..."
$session = New-WinSCPSession -SessionOption $opt
Send-WinSCPItem -WinSCPSession $session -Path C:\temp\svc-user.keytab -Destination /tmp/
Remove-WinSCPSession -WinSCPSession $session
```

---

## Steg 2 – Konfigurer på Debian-serveren

Kopiér repoet til serveren (git clone / scp), så:

```bash
cp config/smbmount.conf.example config/smbmount.conf
nano config/smbmount.conf
```

Sett minst `KRB_PRINCIPAL`, `KRB_KEYTAB`, `SVC_USER`, `MOUNT_GID` og `SHARES`.

---

## Steg 3 – Kjør installasjonen

```bash
# 1) Installer keytab (kopierer til KRB_KEYTAB og tester kinit)
sudo ./setup.sh keytab /tmp/svc-user.keytab

# 2) Full installasjon (pakker + Kerberos + mounts + health + status)
sudo ./setup.sh all
```

Det var alt. `setup.sh all` gjør:

1. `apt install cifs-utils keyutils krb5-user`
2. Oppretter `smb-kinit-<bruker>.service` + `.timer` (fornyer TGT hver 4. time)
3. Skriver en styrt blokk i `/etc/fstab` med `sec=krb5` + `x-systemd.automount`
4. Oppretter mountpunkter og trigger mount
5. Oppretter `smb-health-<bruker>.timer` (sjekk hver time + e-postvarsel)
6. Skriver ut statusrapport

---

## Daglig bruk / feilsøking

```bash
# Statusrapport (TGT, timere, mounts, siste CIFS/krb-logg)
sudo /usr/local/sbin/smb-kerb-status.sh

# Tving fornyelse av TGT manuelt
sudo systemctl start smb-kinit-plex.service
sudo -u plex env -i KRB5CCNAME=KEYRING:persistent:$(id -u plex) klist

# Automount sitter fast i "mount-start-limit-hit"?
sudo /usr/local/sbin/smb-fix-automounts.sh
```

### Etter manuell `umount`
Automounten remountes automatisk ved neste tilgang så lenge `.automount` er
aktiv (`active (waiting)`):

```bash
ls /mount/media >/dev/null   # trigger remount
mount | grep -i media
```

---

## Oppdater keytab (etter passord-reset)

Når passordet til AD-tjenestebrukeren byttes/roteres, blir den gamle keytaben
ugyldig og mounts med `sec=krb5` slutter å virke. Gjør dette for å fornye:

**1) Windows/AD – lag ny keytab** (resetter passord + genererer AES-nøkler):

```powershell
.\windows\New-SmbKeytab.ps1 `
    -SamAccountName SVC-User `
    -Realm AD.EXAMPLE.COM `
    -NetbiosDomain EXAMPLE `
    -OutFile C:\temp\svc-user.keytab `
    -ResetPassword
```

> Er passordet allerede satt i AD og du bare trenger en ny keytab, kjør samme
> kommando **uten** `-ResetPassword` (oppgi gjeldende passord når du blir spurt).

**2) Windows – last opp til serveren:**

```powershell
.\windows\Copy-KeytabToServer.ps1 `
    -Server debian-server.ad.example.com `
    -Username svc-admin `
    -KeytabPath C:\temp\svc-user.keytab `
    -SshHostKeyFingerprint "ssh-ed25519 256 xx:xx:..."
```

**3) Debian – installer ny keytab og test (henter ny TGT):**

```bash
sudo ./setup.sh keytab /tmp/svc-user.keytab
```

`keytab`-kommandoen kopierer fila til `KRB_KEYTAB`, setter rettigheter og kjører
`kinit` som verifisering.

**4) Debian – tving fornyelse og verifiser:**

```bash
sudo systemctl restart smb-kinit-plex.service
sudo -u plex env -i KRB5CCNAME=KEYRING:persistent:$(id -u plex) klist
```

Ser du en gyldig TGT i `klist`, er du i mål. Mountene henter ny billett ved
neste tilgang (`sudo /usr/local/sbin/smb-fix-automounts.sh` om noen sitter fast).

---

## Delkommandoer i `setup.sh`

| Kommando | Hva den gjør |
|----------|--------------|
| `all` | Full installasjon (default) |
| `keytab <fil>` | Installer keytab til `KRB_KEYTAB` og test `kinit` |
| `deps` | Installer pakker |
| `kerberos` | kinit-tjeneste + timer + første billett |
| `mounts` | fstab-blokk + mountpunkter + automount |
| `health` | health/status/fix-scripts + timer |
| `status` | Skriv statusrapport |
| `uninstall` | Fjern systemd-enheter + fstab-blokk for instansen |

---

## Flere servere / flere brukere

Kopiér repoet til hver server og lag en egen `config/smbmount.conf` med riktig
`SVC_USER`, `KRB_PRINCIPAL`, `KRB_KEYTAB` og `SHARES`. Trenger du **flere
tjenestebrukere på samme server**, sett ulik `INSTANCE` per konfig og kjør
`setup.sh` én gang per konfig (bruk `CONFIG=/sti/til/annen.conf sudo -E ./setup.sh all`).

---

## Plex-spesifikt (valgfritt)

Vil du at Plex skal starte etter at TGT er hentet:

```bash
sudo systemctl edit plexmediaserver.service
```
```ini
[Unit]
After=smb-kinit-plex.service
Requires=smb-kinit-plex.service
```

---

## Sikkerhet

- Keytab gir tilgang som tjenestebrukeren – lagres `600`, eies av `root` i
  `/etc/krb5.keytabs/`.
- `seal` (SMB-kryptering) er på som standard i mount-valgene.
- Ikke sjekk inn ekte keytab-filer eller passord i git.
