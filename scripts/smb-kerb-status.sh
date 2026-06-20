#!/usr/bin/env bash
# =============================================================================
#  smb-kerb-status.sh  –  rask statusrapport for Kerberos + CIFS-automounts
# =============================================================================
set -euo pipefail

source /etc/smbmount/smbmount.conf
: "${SVC_UID:=$(id -u "${SVC_USER}")}"
INSTANCE="${INSTANCE:-$SVC_USER}"
CCACHE="KEYRING:persistent:${SVC_UID}"
AUTOMOUNT_PREFIX="${AUTOMOUNT_PREFIX:-/mount/}"

line() { printf '%s\n' "------------------------------------------------------------"; }

echo "== SMB / Kerberos status ($(date -Is)) =="
line
echo "[1/6] TGT i KEYRING for ${SVC_USER} (uid=${SVC_UID})"
if sudo -u "${SVC_USER}" env -i KRB5CCNAME="${CCACHE}" klist >/tmp/.klist.out 2>&1; then
  sed -n '1,6p' /tmp/.klist.out
else
  echo "!! Ingen TGT i ${CCACHE} (kjør: systemctl start smb-kinit-${INSTANCE}.service)"
fi

line
echo "[2/6] Krypteringstyper på TGT/billetter (AES vs RC4)"
# RC4 (arcfour-hmac) er deprecated i MIT Kerberos (Debian 13/krb5 1.21+) og blir
# slått av i en fremtidig versjon. Flagg billetter som fortsatt bruker RC4/DES.
if sudo -u "${SVC_USER}" env -i KRB5CCNAME="${CCACHE}" klist -e >/tmp/.kliste.out 2>&1; then
  # Vis prinsipal + enctype-linjer
  grep -E 'Default principal|Etype|Ticket etype|arcfour|aes|des|rc4' /tmp/.kliste.out \
    | sed -n '1,20p' || true
  if grep -Eqi 'arcfour|rc4|des-cbc|des3' /tmp/.kliste.out; then
    echo "!! ADVARSEL: minst én billett bruker RC4/DES (deprecated på Debian 13)."
    echo "   -> Gi kontoen AES i AD og reset passordet, eller re-join maskinkontoen."
    echo "   -> Se KERBEROS-RC4-DEPRECATION for fremgangsmåte."
  else
    echo "OK: ingen RC4/DES funnet – billetter ser ut til å bruke AES."
  fi
else
  echo "-- Klarte ikke lese billetter (mangler TGT?) – hopper over enctype-sjekk."
fi

line
echo "[3/6] Timere (kinit & health)"
systemctl list-timers --all | grep -E "smb-kinit-${INSTANCE}|smb-health-${INSTANCE}" || true

line
echo "[4/6] Automount-enheter (under ${AUTOMOUNT_PREFIX})"
systemctl list-units --type=automount --all --no-legend --plain \
| awk '{print $1}' \
| while read -r u; do
    where=$(systemctl show -p Where --value "$u")
    [[ -n "$where" && "$where" == ${AUTOMOUNT_PREFIX}* ]] || continue
    state=$(systemctl is-active "$u" || true)
    printf "%-40s %-8s %s\n" "$u" "$state" "$where"
  done

line
echo "[5/6] Aktive CIFS-mounts"
findmnt -t cifs -o TARGET,SOURCE,OPTIONS | sed -n '1,12p' || true

line
echo "[6/6] Siste kjerne-/CIFS-/Kerberos-linjer"
journalctl -k -b | grep -Ei 'cifs|spnego|krb5|cifs\.upcall' | tail -n 40 || true
line
