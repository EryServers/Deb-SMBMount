#!/usr/bin/env bash
# =============================================================================
#  smb-kinit.sh  –  henter/fornyer Kerberos-TGT inn i tjenestebrukerens keyring
#  Kjøres som root av systemd-tjenesten smb-kinit-<instance>.service.
# =============================================================================
set -euo pipefail

source /etc/smbmount/smbmount.conf
: "${SVC_UID:=$(id -u "${SVC_USER}")}"
CCACHE="KEYRING:persistent:${SVC_UID}"

export KRB5CCNAME="${CCACHE}"
exec /usr/bin/kinit -k -t "${KRB_KEYTAB}" "${KRB_PRINCIPAL}"
