#!/usr/bin/env bash
# =============================================================================
#  smb-fix-automounts.sh  –  nullstiller failed-state, hever start-rate-grensen
#  og re-trigger alle CIFS-automounts under et prefiks (default /mount/).
#  Bruk når en automount har havnet i "mount-start-limit-hit".
# =============================================================================
set -euo pipefail

source /etc/smbmount/smbmount.conf
: "${SVC_UID:=$(id -u "${SVC_USER}")}"
INSTANCE="${INSTANCE:-$SVC_USER}"
CCACHE="KEYRING:persistent:${SVC_UID}"
KINIT_SVC="smb-kinit-${INSTANCE}.service"

CHECK_TGT="${CHECK_TGT:-1}"
ONLY_PREFIX="${ONLY_PREFIX:-/mount/}"
SL_INTERVAL="${SL_INTERVAL:-30min}"
SL_BURST="${SL_BURST:-20}"

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()   { echo -e "\033[1;32m[ OK ]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

have_tgt() { KRB5CCNAME="$CCACHE" klist -s 2>/dev/null; }

ensure_tgt() {
  [[ "$CHECK_TGT" == "1" ]] || { warn "Hopper over TGT-sjekk (CHECK_TGT=0)."; return 0; }
  if have_tgt; then
    ok "TGT for ${SVC_USER} (uid=${SVC_UID}) finnes."
  else
    warn "Ingen TGT. Forsøker ${KINIT_SVC} …"
    systemctl start "${KINIT_SVC}" || true
    sleep 2
    have_tgt && ok "TGT hentet." || { err "Fikk ikke TGT. Avbryter."; exit 1; }
  fi
}

write_override() {
  local unit="$1" dir file
  dir="/etc/systemd/system/${unit}.d"
  file="${dir}/override.conf"
  mkdir -p "$dir"
  cat >"$file" <<EOF
[Unit]
StartLimitIntervalSec=${SL_INTERVAL}
StartLimitBurst=${SL_BURST}
EOF
  echo "$file"
}

trigger_and_check() {
  local where="$1" name="$2"
  mkdir -p "$where" 2>/dev/null || true
  timeout 10 bash -lc "ls -1 \"${where}\" >/dev/null 2>&1" || true
  if findmnt -n -t cifs --target "$where" >/dev/null 2>&1; then
    ok "Mounted: $name at $where"; return 0
  else
    warn "Ikke mounted: $name ($where) – sjekk journal."; return 1
  fi
}

main() {
  info "${SVC_USER} UID=${SVC_UID}, ccache=${CCACHE}"
  ensure_tgt

  mapfile -t units < <(systemctl list-units --type=automount --all --no-legend --plain | awk '{print $1}' | sed '/^$/d')
  [[ ${#units[@]} -gt 0 ]] || { err "Fant ingen .automount-enheter."; exit 1; }

  declare -A MPS; filtered=()
  for u in "${units[@]}"; do
    where=$(systemctl show -p Where --value "$u" 2>/dev/null || true)
    [[ -z "$where" ]] && continue
    [[ -n "$ONLY_PREFIX" && "$where" != ${ONLY_PREFIX}* ]] && continue
    MPS["$u"]="$where"; filtered+=("$u")
  done
  [[ ${#filtered[@]} -gt 0 ]] || { err "Ingen automounts matcher '${ONLY_PREFIX}'. Sett ONLY_PREFIX=''."; exit 1; }

  info "Skriver drop-in override (StartLimitIntervalSec=${SL_INTERVAL}, StartLimitBurst=${SL_BURST}) …"
  for u in "${filtered[@]}"; do ok "Skrev $(write_override "$u")"; done

  info "daemon-reload …"; systemctl daemon-reload

  info "Resetter failed-state og restarter automounts …"
  for u in "${filtered[@]}"; do
    m="${u%.automount}.mount"
    systemctl reset-failed "$u" "$m" 2>/dev/null || true
    systemctl stop "$u" >/dev/null 2>&1 || true
    systemctl start "$u"
    ok "Automount aktiv: $u → $(systemctl show -p Where --value "$u")"
  done

  info "Trigger og verifiser …"; failures=0
  for u in "${filtered[@]}"; do
    trigger_and_check "${MPS[$u]}" "${u%.automount}.mount" || ((failures++)) || true
  done

  if (( failures > 0 )); then
    warn "Noen mounts feilet (antall=$failures). Se:"
    warn "  journalctl -k -b | grep -Ei 'cifs|spnego|krb5|cifs\\.upcall' | tail -120"
  else
    ok "Alle valgte automounts er OK."
  fi
}

main "$@"
