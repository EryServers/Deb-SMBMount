#!/usr/bin/env bash
# =============================================================================
#  lib/common.sh  –  felles funksjoner for smbmount-verktøyene
#  Source-es av setup.sh og (deployet) av vedlikeholds-scriptene.
# =============================================================================

# --- Logging -----------------------------------------------------------------
info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()   { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
die()   { err "$*"; exit 1; }

# --- Konfig ------------------------------------------------------------------
# Finn og last konfig. Rekkefølge:
#   1) $CONFIG (miljøvariabel)
#   2) ./config/smbmount.conf  (relativt til repo)
#   3) /etc/smbmount/smbmount.conf  (deployet)
smb_load_config() {
  local candidates=()
  [[ -n "${CONFIG:-}" ]] && candidates+=("$CONFIG")
  candidates+=("$(dirname "${BASH_SOURCE[0]}")/../config/smbmount.conf")
  candidates+=("/etc/smbmount/smbmount.conf")

  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      # shellcheck disable=SC1090
      source "$c"
      SMB_CONFIG_FILE="$c"
      smb_derive_defaults
      return 0
    fi
  done
  die "Fant ingen konfig. Kopier config/smbmount.conf.example til config/smbmount.conf."
}

# Avled verdier som kan utledes av andre.
smb_derive_defaults() {
  : "${SVC_USER:?SVC_USER må være satt i konfig}"
  : "${KRB_PRINCIPAL:?KRB_PRINCIPAL må være satt i konfig}"
  : "${KRB_KEYTAB:?KRB_KEYTAB må være satt i konfig}"

  if [[ -z "${SVC_UID:-}" ]]; then
    SVC_UID="$(id -u "$SVC_USER" 2>/dev/null)" \
      || die "Klarte ikke finne UID for bruker '$SVC_USER'. Sett SVC_UID i konfig."
  fi

  INSTANCE="${INSTANCE:-$SVC_USER}"
  MOUNT_GID="${MOUNT_GID:-985}"
  SMB_VERS="${SMB_VERS:-3.1.1}"
  IDLE_TIMEOUT="${IDLE_TIMEOUT:-300}"

  KRB_REALM="${KRB_PRINCIPAL##*@}"
  CCACHE="KEYRING:persistent:${SVC_UID}"

  KINIT_SVC="smb-kinit-${INSTANCE}.service"
  KINIT_TIMER="smb-kinit-${INSTANCE}.timer"
  HEALTH_SVC="smb-health-${INSTANCE}.service"
  HEALTH_TIMER="smb-health-${INSTANCE}.timer"
}

# Har plex-brukeren en gyldig TGT?
smb_have_tgt() {
  KRB5CCNAME="${CCACHE}" klist -s 2>/dev/null
}
