#!/usr/bin/env bash
# =============================================================================
#  smb-kerb-health.sh  –  sjekker at TGT finnes, auto-recovery + e-postvarsel
#  Kjøres som root av smb-health-<instance>.service (via timer, hver time).
#  Sender e-post KUN ved tilstandsendring (OK <-> FAIL).
# =============================================================================
set -euo pipefail

source /etc/smbmount/smbmount.conf
: "${SVC_UID:=$(id -u "${SVC_USER}")}"
INSTANCE="${INSTANCE:-$SVC_USER}"
CCACHE="KEYRING:persistent:${SVC_UID}"
KINIT_SVC="smb-kinit-${INSTANCE}.service"

STATE_DIR="/var/lib/smb-kerb-health/${INSTANCE}"
STATE_FILE="${STATE_DIR}/state"
LOCK_FILE="${STATE_DIR}/health.lock"
HOST="$(hostname -f 2>/dev/null || hostname)"
TO_ADDR="${ALERT_TO:-root@localhost}"
FROM_ADDR="${FROM_ADDR:-smb-alerts@${HOST}}"
SENDMAIL="${SENDMAIL:-/usr/sbin/sendmail}"

mkdir -p "${STATE_DIR}"; chmod 750 "${STATE_DIR}"

exec 9>"${LOCK_FILE}"
flock -n 9 || exit 0

now_iso() { date -Iseconds; }
have_tgt() { KRB5CCNAME="${CCACHE}" klist -s 2>/dev/null; }

send_mail() {
  [[ -x "${SENDMAIL}" ]] || { warn_no_mail "$1"; return 0; }
  "${SENDMAIL}" -t <<EOF
To: ${TO_ADDR}
Subject: $1
From: ${FROM_ADDR}
Content-Type: text/plain; charset=UTF-8

$2
EOF
}
warn_no_mail() { echo "[health] sendmail mangler – ville sendt: $1" >&2; }

prev="OK"
[[ -f "${STATE_FILE}" ]] && prev="$(cat "${STATE_FILE}" || true)"

if have_tgt; then
  curr="OK"
else
  systemctl start "${KINIT_SVC}" || true
  sleep 2
  if have_tgt; then curr="OK"; else curr="FAIL"; fi
fi

if [[ "${curr}" != "${prev}" ]]; then
  if [[ "${curr}" == "FAIL" ]]; then
    send_mail "[SMB-KRB][${HOST}] TGT MISSING (${INSTANCE})" \
"Time: $(now_iso)
Host: ${HOST}
User: ${SVC_USER} (uid=${SVC_UID})
Cache: ${CCACHE}

Kerberos TGT mangler etter autorecovery-forsøk.
Mounts med sec=krb5 kan feile inntil dette er rettet.

Sjekk:
  sudo journalctl -u ${KINIT_SVC} -o cat --no-pager
  sudo -u ${SVC_USER} env -i KRB5CCNAME=${CCACHE} klist
"
  else
    send_mail "[SMB-KRB][${HOST}] RECOVERY (${INSTANCE})" \
"Time: $(now_iso)
Host: ${HOST}
User: ${SVC_USER} (uid=${SVC_UID})
Cache: ${CCACHE}

Kerberos TGT er tilgjengelig igjen (OK)."
  fi
fi

echo -n "${curr}" > "${STATE_FILE}"
exit 0
