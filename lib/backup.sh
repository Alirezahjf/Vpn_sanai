#!/usr/bin/env bash
# =============================================================================
#  vpn-sanai :: lib/backup.sh
#  Consistent backups of the panel database + vpn-sanai state, cron scheduling,
#  retention and restore.
#
#  The database is dumped with SQLite's online backup API when possible
#  (sqlite3 .backup / VACUUM INTO), which is safe while the panel runs. The
#  panel's own download endpoint is used as a fallback, and a plain copy of the
#  file as the last resort (with a warning).
# =============================================================================

BACKUP_CRON_FILE="/etc/cron.d/vpn-sanai-backup"
BACKUP_TAG="vpn-sanai-backup"

# --- producing a backup ------------------------------------------------------
_db_dump_to() {
    local dest="$1"
    local db; db="$(panel_db_path)"

    [[ -f "$db" ]] || return 1

    if has_cmd sqlite3; then
        if sqlite3 "$db" ".timeout 5000" ".backup '${dest}'" 2>/dev/null && [[ -s "$dest" ]]; then
            log_debug "پشتیبان با sqlite3 .backup ساخته شد"
            return 0
        fi
    fi

    # Fallback: ask the panel for the database (it serialises safely itself).
    if [[ -n "${PANEL_API_TOKEN:-}" ]]; then
        local url; url="$(api_url "/panel/api/server/getDb")"
        if curl -sk --max-time 30 -H "Authorization: Bearer ${PANEL_API_TOKEN}" -o "$dest" "$url" 2>/dev/null \
           && [[ -s "$dest" ]] && head -c 16 "$dest" | grep -q 'SQLite format 3'; then
            log_debug "پشتیبان از طریق API پنل گرفته شد"
            return 0
        fi
    fi

    log_warn "پشتیبان‌گیری آنلاین ممکن نشد؛ کپی ساده از فایل دیتابیس گرفته می‌شود"
    cp -f "$db" "$dest" 2>/dev/null && [[ -s "$dest" ]]
}

# backup_create [label] -> prints the archive path
backup_create() {
    local label="${1:-manual}"
    local stamp dir archive
    stamp="$(date '+%Y%m%d-%H%M%S')"
    dir="${VPN_SANAI_BACKUP_DIR}/${stamp}-${label}"
    archive="${VPN_SANAI_BACKUP_DIR}/${BACKUP_TAG}-${stamp}-${label}.tar.gz"

    ensure_dir "$VPN_SANAI_BACKUP_DIR" 700
    ensure_dir "$dir" 700

    log_step "تهیهٔ پشتیبان (${label})"

    if ! _db_dump_to "${dir}/x-ui.db"; then
        rm -rf "$dir"
        return 1
    fi

    # Secrets and state
    [[ -f "$VPN_SANAI_STATE_FILE" ]] && cp -f "$VPN_SANAI_STATE_FILE" "${dir}/state.env"
    [[ -r "$XUI_INSTALL_RESULT" ]] && cp -f "$XUI_INSTALL_RESULT" "${dir}/install-result.env" || true
    [[ -d "${VPN_SANAI_ETC}/tls" ]] && cp -a "${VPN_SANAI_ETC}/tls" "${dir}/tls" 2>/dev/null || true
    if is_true "$INCLUDE_LINKS_IN_BACKUP" && [[ -d "$VPN_SANAI_LINKS_DIR" ]]; then
        cp -a "$VPN_SANAI_LINKS_DIR" "${dir}/links" 2>/dev/null || true
    fi

    # Panel config (xray template lives in the DB, but the unit file and the
    # generated xray config.json are useful for forensics)
    [[ -f "$XUI_SYSTEMD_UNIT" ]] && cp -f "$XUI_SYSTEMD_UNIT" "${dir}/x-ui.service" || true
    [[ -f "${XUI_FOLDER}/bin/config.json" ]] && cp -f "${XUI_FOLDER}/bin/config.json" "${dir}/xray-config.json" || true
    [[ -f /etc/fail2ban/jail.d/99-vpn-sanai-sshd.local ]] && cp -f /etc/fail2ban/jail.d/99-vpn-sanai-sshd.local "${dir}/" || true

    cat > "${dir}/MANIFEST.txt" <<EOF
vpn-sanai backup
created : $(date '+%Y-%m-%d %H:%M:%S %Z')
host    : $(hostname)
os      : ${OS_PRETTY:-unknown}
panel   : $(panel_version 2>/dev/null || echo unknown)
server  : ${SERVER_IP:-unknown}
inbound : ${VLESS_INBOUND_ID:-?}  port ${VLESS_PORT:-?}  sni ${VLESS_SNI:-?}
label   : ${label}
EOF

    if ! tar -czf "$archive" -C "$VPN_SANAI_BACKUP_DIR" "$(basename "$dir")" 2>/dev/null; then
        log_error "ساخت آرشیو پشتیبان ناموفق بود"
        rm -rf "$dir"
        return 1
    fi
    rm -rf "$dir"
    chmod 600 "$archive"

    log_ok "پشتیبان ساخته شد: ${archive} ($(du -h "$archive" 2>/dev/null | awk '{print $1}'))"
    printf '%s' "$archive"
}

# backup_prune [days] -> deletes archives older than N days
backup_prune() {
    local days="${1:-$BACKUP_KEEP_DAYS}"
    [[ -d "$VPN_SANAI_BACKUP_DIR" ]] || return 0
    local deleted=0
    while IFS= read -r f; do
        rm -f "$f" && ((deleted++))
    done < <(find "$VPN_SANAI_BACKUP_DIR" -maxdepth 1 -name "${BACKUP_TAG}-*.tar.gz" -type f -mtime "+${days}" 2>/dev/null)
    ((deleted > 0)) && log_info "${deleted} پشتیبان قدیمی‌تر از ${days} روز پاک شد"
    return 0
}

backup_list() {
    [[ -d "$VPN_SANAI_BACKUP_DIR" ]] || { log_info "هنوز پشتیبانی ساخته نشده است"; return 0; }
    find "$VPN_SANAI_BACKUP_DIR" -maxdepth 1 -name "${BACKUP_TAG}-*.tar.gz" -type f -printf '%TY-%Tm-%Td %TH:%TM  %10s  %p\n' 2>/dev/null | sort -r
}

# --- restore -----------------------------------------------------------------
# backup_restore [archive] -> restores the database and state into place
backup_restore() {
    local archive="${1:-}"
    if [[ -z "$archive" ]]; then
        archive="$(backup_list | head -1 | awk '{print $NF}')"
    fi
    [[ -n "$archive" && -f "$archive" ]] || die "فایل پشتیبان پیدا نشد"

    log_step "بازگردانی از ${archive}"
    local tmp; tmp="$(mktemp -d)"
    tar -xzf "$archive" -C "$tmp" || die "باز کردن آرشیو ناموفق بود"

    local root; root="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)"
    [[ -n "$root" ]] || die "ساختار آرشیو نامعتبر است"

    panel_service_ctl stop || true
    sleep 2

    if [[ -f "${root}/x-ui.db" ]]; then
        cp -f "$(panel_db_path)" "$(panel_db_path).before-restore.$(date +%s)" 2>/dev/null || true
        cp -f "${root}/x-ui.db" "$(panel_db_path)" || die "بازگردانی دیتابیس ناموفق بود"
        log_ok "دیتابیس پنل بازگردانی شد"
    fi
    if [[ -f "${root}/state.env" ]]; then
        cp -f "${root}/state.env" "$VPN_SANAI_STATE_FILE"
        chmod 600 "$VPN_SANAI_STATE_FILE"
        log_ok "state.env بازگردانی شد"
    fi
    if [[ -d "${root}/tls" ]]; then
        cp -a "${root}/tls" "${VPN_SANAI_ETC}/" 2>/dev/null || true
    fi
    if [[ -d "${root}/links" ]]; then
        cp -a "${root}/links" "${VPN_SANAI_ETC}/" 2>/dev/null || true
    fi

    rm -rf "$tmp"
    panel_service_ctl start || true
    sleep 3
    log_ok "بازگردانی تمام شد؛ وضعیت پنل: $(panel_service_status)"
}

# --- cron --------------------------------------------------------------------
backup_cron_install() {
    is_true "$BACKUP_ENABLED" || { log_info "پشتیبان‌گیری زمان‌بندی‌شده غیرفعال است"; return 0; }
    local cron_expr="${BACKUP_CRON:-$BACKUP_CRON_DEFAULT}"
    local script="${VPN_SANAI_SELF%/*}/scripts/backup.sh"
    [[ -x "$script" ]] || script="$(command -v vpn-sanai-backup 2>/dev/null || true)"
    [[ -n "$script" ]] || { log_warn "اسکریپت پشتیبان‌گیری پیدا نشد؛ cron نصب نشد"; return 0; }

    log_step "زمان‌بندی پشتیبان‌گیری روزانه (${cron_expr})"
    # When the Telegram bot is configured, the daily result is also pushed to
    # the admins (vpn-sanai-telegram exits 0 silently when unconfigured).
    atomic_write "$BACKUP_CRON_FILE" 644 "$(cat <<EOF
# Managed by ${VPN_SANAI_NAME}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${cron_expr} root ${script} --quiet --prune; rc=\$?; command -v vpn-sanai-telegram >/dev/null 2>&1 && vpn-sanai-telegram --notify "\$( [ \$rc -eq 0 ] && echo '💾 پشتیبان‌گیری روزانه با موفقیت انجام شد' || echo "❌ پشتیبان‌گیری روزانه ناموفق بود (کد \$rc)" )" || true
EOF
)"
    if has_cmd systemctl; then
        run_quiet systemctl enable --now cron 2>/dev/null || run_quiet systemctl enable --now crond 2>/dev/null || true
    fi
    log_ok "پشتیبان‌گیری روزانه فعال شد (نگهداری ${BACKUP_KEEP_DAYS} روز)"
}

backup_cron_remove() {
    [[ -f "$BACKUP_CRON_FILE" ]] && rm -f "$BACKUP_CRON_FILE" && log_info "زمان‌بندی پشتیبان‌گیری حذف شد" || true
}

backup_status() {
    kv "مسیر پشتیبان" "$VPN_SANAI_BACKUP_DIR"
    kv "زمان‌بندی" "$([[ -f "$BACKUP_CRON_FILE" ]] && echo 'فعال' || echo 'غیرفعال')"
    local last
    last="$(backup_list | head -1 || true)"
    kv "آخرین پشتیبان" "${last:-ندارد}"
}
