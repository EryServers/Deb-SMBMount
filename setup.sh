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
#    sudo ./setup.sh user               # opprett tjenestebruker (CREATE_SVC_USER=1)
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
KRB5_CONF_D="/etc/krb5.conf.d"
KRB5_CCACHE_DROPIN="${KRB5_CONF_D}/90-smbmount-ccache-keyring.conf"

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

# Legg ccache i kernel keyring per UID, slik at cifs.upcall finner
# Kerberos-billetten ved mount (ellers feiler CIFS-mount med -126/ENOKEY).
# Vi r 0rer IKKE /etc/krb5.conf – vi legger en drop-in i /etc/krb5.conf.d/.
deploy_ccache_dropin() {
  install -d -m 755 "${KRB5_CONF_D}"
  cat > "${KRB5_CCACHE_DROPIN}" <<'EOF'
[libdefaults]
    # Lagt til av smbmount setup.sh.
    # Legg ccache i kernel keyring per UID (CIFS/cifs.upcall finner den her).
    default_ccache_name = KEYRING:persistent:%{uid}
EOF
  chmod 644 "${KRB5_CCACHE_DROPIN}"
  ok "Skrev ccache-keyring drop-in: ${KRB5_CCACHE_DROPIN}"

  # Drop-in virker bare hvis hoved-krb5.conf inkluderer katalogen.
  if ! grep -Eqs '^[[:space:]]*include(dir)?[[:space:]]+/etc/krb5\.conf\.d' /etc/krb5.conf; then
    warn "/etc/krb5.conf mangler 'includedir /etc/krb5.conf.d/' – drop-in blir ignorert."
    warn "Legg til denne linja øverst i /etc/krb5.conf (utenfor alle [seksjoner]):"
    warn "    includedir /etc/krb5.conf.d/"
  fi
}

write_krb5conf() {
  [[ "${MANAGE_KRB5CONF:-0}" == "1" ]] || { info "MANAGE_KRB5CONF=0 – hopper over /etc/krb5.conf."; return 0; }
  local lower="${KRB_REALM,,}"
  cat > /etc/krb5.conf <<EOF
includedir /etc/krb5.conf.d/

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
  deploy_ccache_dropin
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

  warn "Fjerner ccache-keyring drop-in (${KRB5_CCACHE_DROPIN}) …"
  rm -f "${KRB5_CCACHE_DROPIN}"

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
#  Valgfri opprettelse av dedikert tjenestebruker (CREATE_SVC_USER=1)
# -----------------------------------------------------------------------------
ensure_svc_user() {
  local user="${SVC_USER}"
  local grp="${SVC_GROUP:-$user}"
  local home="${SVC_HOME:-/var/lib/${user}}"

  # Gruppe – bruk MOUNT_GID hvis den er satt og ledig, ellers auto-tildelt GID.
  if ! getent group "$grp" >/dev/null 2>&1; then
    if [[ -n "${MOUNT_GID:-}" ]] && ! getent group "${MOUNT_GID}" >/dev/null 2>&1; then
      groupadd --system --gid "${MOUNT_GID}" "$grp"
      ok "Opprettet gruppe '${grp}' med GID ${MOUNT_GID}."
    else
      groupadd --system "$grp"
      local newgid; newgid="$(getent group "$grp" | cut -d: -f3)"
      ok "Opprettet gruppe '${grp}' med auto-tildelt GID ${newgid}."
      if [[ -n "${MOUNT_GID:-}" && "${newgid}" != "${MOUNT_GID}" ]]; then
        local taken; taken="$(getent group "${MOUNT_GID}" | cut -d: -f1)"
        warn "MOUNT_GID=${MOUNT_GID} er allerede i bruk av gruppen '${taken:-?}'."
        warn "Gruppen '${grp}' fikk GID ${newgid} i stedet. Mount-valgene bruker"
        warn "fortsatt gid=${MOUNT_GID}, så filene vil vises som eid av '${taken:-GID ${MOUNT_GID}}'."
        warn "Anbefalt: sett MOUNT_GID=\"${newgid}\" i konfig og kjør 'sudo ./setup.sh mounts' på nytt."
      fi
    fi
  else
    info "Gruppe '${grp}' finnes – hopper over."
  fi

  # Bruker – systembruker uten innlogging (kun for keyring/cruid).
  if ! id -u "$user" >/dev/null 2>&1; then
    local uidopt=()
    if [[ -n "${SVC_UID:-}" ]] && ! getent passwd "${SVC_UID}" >/dev/null 2>&1; then
      uidopt=(--uid "${SVC_UID}")
    fi
    useradd --system "${uidopt[@]}" --gid "$grp" \
            --home-dir "$home" --create-home \
            --shell /usr/sbin/nologin "$user"
    ok "Opprettet systembruker '${user}' (home=${home}, shell=nologin)."
  else
    info "Bruker '${user}' finnes – hopper over."
  fi
  id "$user"
}

# Pre-pass: oppretter bruker FØR UID utledes (id -u i common.sh), slik at
# smb_load_config ikke feiler på manglende bruker. Kjøres bare for kommandoer
# som faktisk installerer/oppretter ting.
pre_create_user() {
  case "${1:-}" in user|kerberos|mounts|all|"") ;; *) return 0 ;; esac
  local cfg="${CONFIG:-${REPO_DIR}/config/smbmount.conf}"
  [[ -f "$cfg" ]] || return 0
  # shellcheck disable=SC1090
  source "$cfg"
  [[ "${CREATE_SVC_USER:-0}" == "1" ]] || return 0
  require_root
  info "CREATE_SVC_USER=1 – sørger for tjenestebruker '${SVC_USER}' …"
  ensure_svc_user
}

cmd_user() {
  require_root
  [[ "${CREATE_SVC_USER:-0}" == "1" ]] \
    || warn "CREATE_SVC_USER er ikke 1 i konfig – oppretter likevel på forespørsel."
  ensure_svc_user
}

# -----------------------------------------------------------------------------
main() {
  local sub="${1:-}"
  pre_create_user "${sub}"
  smb_load_config
  FSTAB_BEGIN="# >>> smbmount managed (${INSTANCE}) >>>"
  FSTAB_END="# <<< smbmount managed (${INSTANCE}) <<<"
  shift || true
  case "${sub}" in
    deps)      cmd_deps ;;
    keytab)    cmd_keytab "$@" ;;
    kerberos)  cmd_kerberos ;;
    mounts)    cmd_mounts ;;
    health)    cmd_health ;;
    user)      cmd_user ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
    all|"")    cmd_all ;;
    *)         die "Ukjent kommando: ${sub}. Se toppen av setup.sh for bruk." ;;
  esac
}

main "$@"
