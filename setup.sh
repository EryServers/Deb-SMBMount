#!/usr/bin/env bash
# =============================================================================
#  setup.sh  –  installerer/konfigurerer Kerberos-baserte CIFS-mounts på Debian
#
#  Kjøres som root PÅ Debian-serveren etter at du har:
#    1) laget keytab på Windows (windows/New-SmbKeytab.ps1) og kopiert den hit
#    2) kopiert config/smbmount.conf.example -> config/smbmount.conf og tilpasset
#
#  Bruk:
#    sudo ./setup.sh all                # full installasjon (anbefalt)
#    sudo ./setup.sh keytab <fil>       # installer keytab til KRB_KEYTAB
#    sudo ./setup.sh deps               # pakker
#    sudo ./setup.sh kerberos           # kinit-tjeneste + timer + første billett
#    sudo ./setup.sh mounts             # fstab + mountpunkter + automount
#    sudo ./setup.sh health             # health/status/fix-scripts + timer
#    sudo ./setup.sh status             # statusrapport
#    sudo ./setup.sh uninstall          # fjern alt dette verktøyet la inn
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"

CONF_DST="/etc/smbmount/smbmount.conf"
SBIN="/usr/local/sbin"
UNIT_DIR="/etc/systemd/system"
FSTAB="/etc/fstab"

require_root() { [[ "${EUID}" -eq 0 ]] || die "Kjør som root (sudo)."; }

# -----------------------------------------------------------------------------
deploy_config() {
  install -d -m 755 /etc/smbmount
  install -m 644 "${SMB_CONFIG_FILE}" "${CONF_DST}"
  ok "Konfig deployet til ${CONF_DST}"
}

deploy_scripts() {
  install -d -m 755 "${SBIN}"
  local s
  for s in smb-kinit smb-kerb-health smb-kerb-status smb-fix-automounts; do
    install -m 755 "${REPO_DIR}/scripts/${s}.sh" "${SBIN}/${s}.sh"
  done
  ok "Scripts deployet til ${SBIN}/"
}

# -----------------------------------------------------------------------------
cmd_deps() {
  require_root
  info "Installerer pakker …"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y cifs-utils keyutils krb5-user
  ok "Pakker installert."
}

cmd_keytab() {
  require_root
  local src="${1:-}"
  [[ -n "$src" && -f "$src" ]] || die "Bruk: setup.sh keytab <sti-til-keytab>"
  install -d -m 750 "$(dirname "${KRB_KEYTAB}")"
  install -m 600 "$src" "${KRB_KEYTAB}"
  ok "Keytab installert: ${KRB_KEYTAB}"
  info "Tester keytab (kinit) …"
  KRB5CCNAME="${CCACHE}" kinit -k -t "${KRB_KEYTAB}" "${KRB_PRINCIPAL}" \
    && KRB5CCNAME="${CCACHE}" klist \
    || die "kinit feilet – sjekk prinsipp/keytab/krb5.conf."
}

write_krb5conf() {
  [[ "${MANAGE_KRB5CONF:-0}" == "1" ]] || { info "MANAGE_KRB5CONF=0 – hopper over /etc/krb5.conf."; return 0; }
  local lower="${KRB_REALM,,}"
  cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${KRB_REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    rdns = false
    forwardable = true

[domain_realm]
    .${lower} = ${KRB_REALM}
    ${lower} = ${KRB_REALM}
EOF
  ok "Skrev /etc/krb5.conf (realm=${KRB_REALM})"
}

cmd_kerberos() {
  require_root
  deploy_config
  deploy_scripts
  write_krb5conf

  info "Skriver ${KINIT_SVC} …"
  cat > "${UNIT_DIR}/${KINIT_SVC}" <<EOF
[Unit]
Description=Obtain Kerberos TGT for ${KRB_PRINCIPAL} into ${SVC_USER} keyring
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=KRB5CCNAME=${CCACHE}
ExecStart=${SBIN}/smb-kinit.sh

[Install]
WantedBy=multi-user.target
EOF

  info "Skriver ${KINIT_TIMER} …"
  cat > "${UNIT_DIR}/${KINIT_TIMER}" <<EOF
[Unit]
Description=Renew Kerberos TGT for ${KRB_PRINCIPAL}

[Timer]
OnBootSec=30s
OnUnitActiveSec=4h
Persistent=true
Unit=${KINIT_SVC}

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${KINIT_SVC}" "${KINIT_TIMER}"
  sleep 1
  if smb_have_tgt; then
    ok "TGT hentet for ${SVC_USER}:"
    sudo -u "${SVC_USER}" env -i KRB5CCNAME="${CCACHE}" klist || true
  else
    warn "Ingen TGT enda – sjekk: journalctl -u ${KINIT_SVC} -o cat --no-pager"
  fi
}

# -----------------------------------------------------------------------------
build_fstab_block() {
  local opts entry unc mp
  opts="vers=${SMB_VERS},sec=krb5,cruid=${SVC_UID},uid=${SVC_UID},gid=${MOUNT_GID}"
  opts+=",iocharset=utf8,noserverino,_netdev,x-systemd.automount"
  opts+=",x-systemd.idle-timeout=${IDLE_TIMEOUT},seal,noperm"
  opts+=",x-systemd.requires=${KINIT_SVC},x-systemd.after=${KINIT_SVC}"

  echo "${FSTAB_BEGIN}"
  echo "# Generert av smbmount setup.sh – ikke rediger mellom markørene for hånd."
  for entry in "${SHARES[@]}"; do
    unc="${entry%%|*}"
    mp="${entry##*|}"
    printf '%s %s cifs %s 0 0\n' "${unc}" "${mp}" "${opts}"
  done
  echo "${FSTAB_END}"
}

cmd_mounts() {
  require_root
  deploy_config

  info "Oppretter mountpunkter …"
  local entry mp
  for entry in "${SHARES[@]}"; do
    mp="${entry##*|}"
    install -d -m 755 "${mp}"
  done

  info "Oppdaterer ${FSTAB} (managed-blokk for instans '${INSTANCE}') …"
  cp -a "${FSTAB}" "${FSTAB}.smbmount.bak.$(date +%Y%m%d%H%M%S)"
  # Fjern eksisterende blokk for denne instansen, behold resten.
  local tmp; tmp="$(mktemp)"
  awk -v b="${FSTAB_BEGIN}" -v e="${FSTAB_END}" '
    $0==b {skip=1} !skip {print} $0==e {skip=0}
  ' "${FSTAB}" > "${tmp}"
  # Trim trailing blanke linjer, så legg blokken til slutt.
  printf '\n' >> "${tmp}"
  build_fstab_block >> "${tmp}"
  install -m 644 "${tmp}" "${FSTAB}"
  rm -f "${tmp}"
  ok "fstab oppdatert (backup tatt)."

  systemctl daemon-reload

  info "Starter automounts og trigger mount …"
  for entry in "${SHARES[@]}"; do
    mp="${entry##*|}"
    local amunit; amunit="$(systemd-escape -p --suffix=automount "${mp}")"
    systemctl reset-failed "${amunit}" 2>/dev/null || true
    systemctl start "${amunit}" 2>/dev/null || warn "Klarte ikke starte ${amunit}"
    timeout 10 bash -lc "ls -1 \"${mp}\" >/dev/null 2>&1" || true
    if findmnt -n -t cifs --target "${mp}" >/dev/null 2>&1; then
      ok "Mounted: ${mp}"
    else
      warn "Ikke mounted enda: ${mp} (kjør 'sudo ${SBIN}/smb-fix-automounts.sh' ved behov)"
    fi
  done
}

# -----------------------------------------------------------------------------
cmd_health() {
  require_root
  deploy_config
  deploy_scripts

  info "Skriver ${HEALTH_SVC} …"
  cat > "${UNIT_DIR}/${HEALTH_SVC}" <<EOF
[Unit]
Description=Health check: ${KRB_PRINCIPAL} Kerberos ticket in ${SVC_USER} keyring

[Service]
Type=oneshot
ExecStart=${SBIN}/smb-kerb-health.sh
EOF

  info "Skriver ${HEALTH_TIMER} …"
  cat > "${UNIT_DIR}/${HEALTH_TIMER}" <<EOF
[Unit]
Description=Run SMB Kerberos health check hourly (${INSTANCE})

[Timer]
OnBootSec=10min
OnCalendar=hourly
Persistent=true
Unit=${HEALTH_SVC}

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${HEALTH_TIMER}"
  ok "Health-timer aktivert."
  systemctl list-timers --all | grep -E "smb-kinit-${INSTANCE}|smb-health-${INSTANCE}" || true
}

# -----------------------------------------------------------------------------
cmd_status() { require_root; "${SBIN}/smb-kerb-status.sh"; }

cmd_uninstall() {
  require_root
  warn "Deaktiverer og fjerner systemd-enheter for instans '${INSTANCE}' …"
  systemctl disable --now "${KINIT_TIMER}" "${KINIT_SVC}" "${HEALTH_TIMER}" "${HEALTH_SVC}" 2>/dev/null || true
  rm -f "${UNIT_DIR}/${KINIT_SVC}" "${UNIT_DIR}/${KINIT_TIMER}" \
        "${UNIT_DIR}/${HEALTH_SVC}" "${UNIT_DIR}/${HEALTH_TIMER}"

  warn "Fjerner fstab-blokk for '${INSTANCE}' (backup tas) …"
  cp -a "${FSTAB}" "${FSTAB}.smbmount.bak.$(date +%Y%m%d%H%M%S)"
  local tmp; tmp="$(mktemp)"
  awk -v b="${FSTAB_BEGIN}" -v e="${FSTAB_END}" '
    $0==b {skip=1} !skip {print} $0==e {skip=0}
  ' "${FSTAB}" > "${tmp}"
  install -m 644 "${tmp}" "${FSTAB}"; rm -f "${tmp}"

  systemctl daemon-reload
  ok "Avinstallert. Scripts i ${SBIN}/ og /etc/smbmount er IKKE fjernet (gjør manuelt ved behov)."
}

# -----------------------------------------------------------------------------
cmd_all() {
  cmd_deps
  [[ -f "${KRB_KEYTAB}" ]] || die "Keytab mangler: ${KRB_KEYTAB}. Kjør 'sudo ./setup.sh keytab <fil>' først."
  cmd_kerberos
  cmd_mounts
  cmd_health
  cmd_status
}

# -----------------------------------------------------------------------------
main() {
  smb_load_config
  FSTAB_BEGIN="# >>> smbmount managed (${INSTANCE}) >>>"
  FSTAB_END="# <<< smbmount managed (${INSTANCE}) <<<"
  local sub="${1:-}"; shift || true
  case "${sub}" in
    deps)      cmd_deps ;;
    keytab)    cmd_keytab "$@" ;;
    kerberos)  cmd_kerberos ;;
    mounts)    cmd_mounts ;;
    health)    cmd_health ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
    all|"")    cmd_all ;;
    *)         die "Ukjent kommando: ${sub}. Se toppen av setup.sh for bruk." ;;
  esac
}

main "$@"
