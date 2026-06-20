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
echo "[1/5] TGT i KEYRING for ${SVC_USER} (uid=${SVC_UID})"
if sudo -u "${SVC_USER}" env -i KRB5CCNAME="${CCACHE}" klist >/tmp/.klist.out 2>&1; then
  sed -n '1,6p' /tmp/.klist.out
else
  echo "!! Ingen TGT i ${CCACHE} (kjør: systemctl start smb-kinit-${INSTANCE}.service)"
fi

line
echo "[2/5] Timere (kinit & health)"
systemctl list-timers --all | grep -E "smb-kinit-${INSTANCE}|smb-health-${INSTANCE}" || true

line
echo "[3/5] Automount-enheter (under ${AUTOMOUNT_PREFIX})"
systemctl list-units --type=automount --all --no-legend --plain \
| awk '{print $1}' \
| while read -r u; do
    where=$(systemctl show -p Where --value "$u")
    [[ -n "$where" && "$where" == ${AUTOMOUNT_PREFIX}* ]] || continue
    state=$(systemctl is-active "$u" || true)
    printf "%-40s %-8s %s\n" "$u" "$state" "$where"
  done

line
echo "[4/5] Aktive CIFS-mounts"
findmnt -t cifs -o TARGET,SOURCE,OPTIONS | sed -n '1,12p' || true

line
echo "[5/5] Siste kjerne-/CIFS-/Kerberos-linjer"
journalctl -k -b | grep -Ei 'cifs|spnego|krb5|cifs\.upcall' | tail -n 40 || true
line
