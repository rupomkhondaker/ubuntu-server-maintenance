#!/usr/bin/env bash
# =====================================================================
# Enterprise Safe Ubuntu Server Maintenance Script
# Version: 2.0
# =====================================================================
# Supports:
#   Ubuntu 18.04 / 20.04 / 22.04 / 24.04
#
# Designed for:
#   - Production VPS running PHP + MySQL/MariaDB
#   - Nginx or Apache
#   - Zero-surprise, zero-downtime maintenance
#
# FEATURES
# ---------------------------------------------------------------------
# ✔ Concurrent execution prevention (flock)
# ✔ Strict error handling (set -Eeuo pipefail)
# ✔ Pre-flight disk space check (before AND before backup)
# ✔ Pre-flight service health check
# ✔ HTTP health check with real status code capture
# ✔ Optional content-match health check
# ✔ Automatic MySQL credential detection
# ✔ MySQL backup with empty-file guard + size report
# ✔ Config backup (skips missing directories safely)
# ✔ Backup retention cleanup (auto-removes old backups)
# ✔ PHP + MySQL package pinning (hold before any upgrade)
# ✔ Interactive upgrade confirmation with package preview
# ✔ Safe apt upgrade (no full-upgrade)
# ✔ Post-upgrade service verification with retry loop
# ✔ Automatic service recovery on failure
# ✔ Package cleanup (fix-broken, configure, autoremove dry-run)
# ✔ Journal cleanup with configurable retention
# ✔ Snap cleanup with per-revision logging
# ✔ Log rotation via logrotate drop-in
# ✔ Reboot-required detection (never auto-reboots)
# ✔ Final disk report + top directories
# ✔ Full timestamped log with color terminal output
# ✔ Summary: errors + warnings at exit
#
# INTENTIONAL OMISSIONS (production safety)
# ---------------------------------------------------------------------
# ✘ Does NOT run full-upgrade
# ✘ Does NOT auto-reboot
# ✘ Does NOT change PHP version
# ✘ Does NOT force autoremove without confirmation
#
# USAGE
# ---------------------------------------------------------------------
#   sudo ./server-maintenance-enterprise.sh
#
# =====================================================================

set -Eeuo pipefail

# =====================================================================
# CONFIGURATION  — edit this section for your server
# =====================================================================

PHP_VERSION="7.4"
MYSQL_SERVICE="mysql"           # mysql  or mariadb
WEB_SERVICE="nginx"             # nginx  or apache2

# Leave blank to skip HTTP check
SITE_CHECK_URL="http://localhost"

# Optional: a string that must appear in the HTTP response body
SITE_EXPECTED_TEXT=""

# Where backups are stored
BACKUP_DIR="/backup"

# How many days to keep old backups (0 = keep forever)
BACKUP_RETAIN_DAYS=7

# Minimum free MB on /var before we proceed
MIN_FREE_MB=1024

# Minimum free MB in BACKUP_DIR before we attempt MySQL dump
# (set to 0 to skip this check)
MIN_BACKUP_FREE_MB=512

# How long to retain systemd journal logs
JOURNAL_RETENTION="7d"

# Where to write the maintenance log
LOG_FILE="/var/log/server-maintenance.log"

# Path to logrotate drop-in (created automatically if missing)
LOGROTATE_CONF="/etc/logrotate.d/server-maintenance"

# =====================================================================
# COLORS
# =====================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =====================================================================
# LOCK — prevent concurrent runs
# =====================================================================

LOCK_FILE="/var/run/server-maintenance.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || {
    echo -e "${RED}[LOCK]${NC} Another maintenance process is already running. Exiting."
    exit 1
}

# =====================================================================
# GLOBALS
# =====================================================================

ERRORS=0
WARNINGS=0
START_DATE=$(date +"%Y-%m-%d %H:%M:%S")
PHP_FPM="php${PHP_VERSION}-fpm"

APT_OPTIONS=(
    "-o" "Acquire::Retries=3"
    "-o" "Acquire::http::Timeout=30"
    "-o" "Acquire::https::Timeout=30"
)

# =====================================================================
# LOGGING
# =====================================================================

mkdir -p "$(dirname "$LOG_FILE")"

# All log functions write plain text to file, colored text to terminal
_log_plain() { echo -e "$1" >> "$LOG_FILE"; }
_log_both()  { echo -e "$1" | tee -a "$LOG_FILE"; }

log()     { _log_both "$1"; }
ts()      { _log_both "[$(date +%H:%M:%S)] $1"; }
info()    { _log_both "${BLUE}[INFO]${NC}  $1"; }
ok()      { _log_both "${GREEN}[ OK ]${NC}  $1"; }
warn()    { WARNINGS=$((WARNINGS+1)); _log_both "${YELLOW}[WARN]${NC}  $1"; }
fail()    { ERRORS=$((ERRORS+1));    _log_both "${RED}[FAIL]${NC}  $1"; }
section() {
    _log_both ""
    _log_both "${BOLD}${CYAN}=====================================================================${NC}"
    _log_both "${BOLD}${CYAN}  $1${NC}"
    _log_both "${BOLD}${CYAN}=====================================================================${NC}"
}

run_cmd() {
    # run_cmd "Human description" actual_command [args...]
    local desc="$1"; shift
    ts "Running: $*"
    if "$@" >> "$LOG_FILE" 2>&1; then
        ok "$desc"
        return 0
    else
        fail "$desc"
        return 1
    fi
}

# =====================================================================
# ROOT CHECK
# =====================================================================

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Error:${NC} Please run as root:  sudo $0"
    exit 1
fi

# =====================================================================
# LOGROTATE SETUP
# =====================================================================
# Install a logrotate config the first time so the log never grows
# unboundedly across months of runs.

if [[ ! -f "$LOGROTATE_CONF" ]]; then
    cat > "$LOGROTATE_CONF" <<EOF
$LOG_FILE {
    monthly
    rotate 6
    compress
    missingok
    notifempty
    create 640 root adm
}
EOF
    info "Logrotate config created: $LOGROTATE_CONF"
fi

# =====================================================================
# HEADER
# =====================================================================

section "SERVER MAINTENANCE STARTED"
log "  Start Time  : $START_DATE"
log "  Hostname    : $(hostname)"
log "  Kernel      : $(uname -r)"
log "  PHP         : $PHP_VERSION"
log "  Web Server  : $WEB_SERVICE"
log "  Database    : $MYSQL_SERVICE"
log "  Log File    : $LOG_FILE"
log "  Backup Dir  : $BACKUP_DIR"

# =====================================================================
# DISK SPACE CHECK  (/var)
# =====================================================================

section "DISK SPACE CHECK"

AVAILABLE_MB=$(df /var --output=avail -m | tail -1 | xargs)
log "  Available on /var: ${AVAILABLE_MB}MB  (minimum required: ${MIN_FREE_MB}MB)"

if [[ "$AVAILABLE_MB" -lt "$MIN_FREE_MB" ]]; then
    fail "Insufficient disk space on /var — aborting to avoid making things worse"
    exit 1
else
    ok "Disk space check passed"
fi

# =====================================================================
# PRE-FLIGHT SERVICE CHECK
# =====================================================================

section "PRE-FLIGHT SERVICE CHECK"

PREFLIGHT_FAILURES=0

check_service() {
    local svc="$1"
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
        if systemctl is-active --quiet "$svc"; then
            ok "$svc is running"
        else
            fail "$svc is NOT running before maintenance"
            PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES+1))
        fi
    else
        warn "$svc service unit not found on this system"
    fi
}

check_service "$MYSQL_SERVICE"
check_service "$WEB_SERVICE"
check_service "$PHP_FPM"

if [[ "$PREFLIGHT_FAILURES" -gt 0 ]]; then
    fail "Pre-flight failed: $PREFLIGHT_FAILURES service(s) are down before maintenance started."
    fail "Fix the above issues before running this script."
    exit 1
fi

# =====================================================================
# WEBSITE HEALTH CHECK  (pre-maintenance baseline)
# =====================================================================

section "WEBSITE HEALTH CHECK (PRE)"

http_check() {
    local label="$1"
    if [[ -z "$SITE_CHECK_URL" ]]; then
        info "SITE_CHECK_URL not set — skipping HTTP check"
        return 0
    fi

    # Capture HTTP code and body separately; never let curl failure kill script
    local tmp_body
    tmp_body=$(mktemp)
    local http_code
    http_code=$(curl -s -o "$tmp_body" -w "%{http_code}" \
        --max-time 10 "$SITE_CHECK_URL" 2>/dev/null || echo "000")

    if [[ "$http_code" =~ ^(200|301|302|304)$ ]]; then
        ok "$label — HTTP $http_code from $SITE_CHECK_URL"
    else
        fail "$label — HTTP $http_code from $SITE_CHECK_URL (expected 2xx/3xx)"
    fi

    if [[ -n "$SITE_EXPECTED_TEXT" ]]; then
        if grep -q "$SITE_EXPECTED_TEXT" "$tmp_body" 2>/dev/null; then
            ok "$label — expected content found in response"
        else
            warn "$label — expected content '$SITE_EXPECTED_TEXT' NOT found in response"
        fi
    fi

    rm -f "$tmp_body"
}

http_check "Pre-maintenance"

# =====================================================================
# BACKUPS
# =====================================================================

section "CREATING BACKUPS"

mkdir -p "$BACKUP_DIR/mysql"
mkdir -p "$BACKUP_DIR/configs"

# ── Backup retention cleanup ─────────────────────────────────────────

if [[ "$BACKUP_RETAIN_DAYS" -gt 0 ]]; then
    info "Removing backups older than ${BACKUP_RETAIN_DAYS} days"
    find "$BACKUP_DIR/mysql"   -name "*.sql.gz"  -mtime +"$BACKUP_RETAIN_DAYS" -delete 2>/dev/null || true
    find "$BACKUP_DIR/configs" -name "*.tar.gz"  -mtime +"$BACKUP_RETAIN_DAYS" -delete 2>/dev/null || true
    ok "Old backup retention cleanup done"
fi

# ── MySQL backup ─────────────────────────────────────────────────────

MYSQL_BACKUP="$BACKUP_DIR/mysql/mysql-all-$(date +%F-%H%M).sql"

if systemctl is-active --quiet "$MYSQL_SERVICE"; then

    # Estimate DB size and check backup destination has room
    if [[ "$MIN_BACKUP_FREE_MB" -gt 0 ]]; then
        DB_SIZE_MB=$(mysql --defaults-file=/etc/mysql/debian.cnf \
            -Nse "SELECT CEIL(SUM(data_length+index_length)/1024/1024)
                  FROM information_schema.tables;" 2>/dev/null || echo 0)
        BACKUP_FREE_MB=$(df "$BACKUP_DIR" --output=avail -m | tail -1 | xargs)
        NEEDED_MB=$(( DB_SIZE_MB * 2 ))   # raw SQL ~ 2x compressed, be safe

        log "  DB size estimate: ${DB_SIZE_MB}MB | Free in $BACKUP_DIR: ${BACKUP_FREE_MB}MB"

        if [[ "$BACKUP_FREE_MB" -lt "$NEEDED_MB" ]]; then
            fail "Not enough space in $BACKUP_DIR for MySQL backup (need ~${NEEDED_MB}MB, have ${BACKUP_FREE_MB}MB)"
            warn "Skipping MySQL backup — resolve disk space and retry"
        else
            _do_mysql_backup=true
        fi
    else
        _do_mysql_backup=true
    fi

    if [[ "${_do_mysql_backup:-false}" == "true" ]]; then
        info "Starting MySQL backup → $MYSQL_BACKUP"

        # Use debian.cnf if present (no password needed), else fall back
        MYSQL_DEFAULTS=""
        [[ -f /etc/mysql/debian.cnf ]] && MYSQL_DEFAULTS="--defaults-file=/etc/mysql/debian.cnf"

        # shellcheck disable=SC2086
        if mysqldump $MYSQL_DEFAULTS \
            --all-databases \
            --single-transaction \
            --quick \
            --lock-tables=false \
            > "$MYSQL_BACKUP" 2>> "$LOG_FILE"; then

            # Guard: reject empty or suspiciously tiny dumps
            DUMP_SIZE=$(wc -c < "$MYSQL_BACKUP")
            if [[ "$DUMP_SIZE" -lt 1024 ]]; then
                fail "MySQL dump looks empty or corrupt (${DUMP_SIZE} bytes) — not compressing"
                rm -f "$MYSQL_BACKUP"
            else
                gzip -f "$MYSQL_BACKUP"
                FINAL_SIZE=$(du -sh "${MYSQL_BACKUP}.gz" 2>/dev/null | cut -f1)
                ok "MySQL backup complete — ${MYSQL_BACKUP}.gz (${FINAL_SIZE})"
            fi
        else
            fail "mysqldump command failed — check credentials and service status"
            rm -f "$MYSQL_BACKUP"
        fi
    fi
else
    warn "MySQL service is not running — skipping backup"
fi

# ── Config backup ────────────────────────────────────────────────────

CONFIG_BACKUP="$BACKUP_DIR/configs/configs-$(date +%F-%H%M).tar.gz"

# Only include directories that actually exist on this system
CONFIG_PATHS=()
for dir in /etc/nginx /etc/apache2 /etc/php /etc/mysql /etc/systemd; do
    [[ -d "$dir" ]] && CONFIG_PATHS+=("$dir")
done

if [[ "${#CONFIG_PATHS[@]}" -gt 0 ]]; then
    info "Backing up: ${CONFIG_PATHS[*]}"
    if tar -czf "$CONFIG_BACKUP" "${CONFIG_PATHS[@]}" >> "$LOG_FILE" 2>&1; then
        CONFIG_SIZE=$(du -sh "$CONFIG_BACKUP" | cut -f1)
        ok "Config backup complete — $CONFIG_BACKUP ($CONFIG_SIZE)"
    else
        warn "Config backup completed with warnings (some files may be inaccessible)"
    fi
else
    warn "No config directories found to back up"
fi

# =====================================================================
# PACKAGE INDEX UPDATE + UPGRADE PREVIEW
# =====================================================================

section "PACKAGE DISCOVERY"

run_cmd "Updating package index" \
    apt "${APT_OPTIONS[@]}" update

UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v "^Listing" || true)

if [[ -z "$UPGRADABLE" ]]; then
    ok "No packages pending upgrade"
else
    log ""
    log "  Packages pending upgrade:"
    echo "$UPGRADABLE" | while IFS= read -r line; do
        log "    $line"
    done
    log ""

    if echo "$UPGRADABLE" | grep -qi "php"; then
        warn "PHP packages detected in upgrade list — they will be HELD"
    fi
    if echo "$UPGRADABLE" | grep -qi "mysql\|mariadb"; then
        warn "MySQL/MariaDB packages detected in upgrade list — they will be HELD"
    fi
    if echo "$UPGRADABLE" | grep -qi "nginx\|apache2"; then
        warn "Web server detected in upgrade list — it may restart briefly"
    fi
fi

# =====================================================================
# CONFIRMATION
# =====================================================================

log ""
echo -e "${BOLD}  Review the upgrade list above carefully.${NC}"
echo ""
read -r -p "  Proceed with maintenance? [y/N]: " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warn "Maintenance cancelled by user at confirmation prompt"
    exit 0
fi

# =====================================================================
# HOLD CRITICAL PACKAGES
# =====================================================================

section "HOLDING CRITICAL PACKAGES"

# Discover all installed PHP $PHP_VERSION and MySQL/MariaDB packages
PHP_PACKAGES=$(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null \
    | grep "^php${PHP_VERSION}" || true)

MYSQL_PACKAGES=$(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null \
    | grep -E '^(mysql|mariadb)' || true)

if [[ -n "$PHP_PACKAGES" ]]; then
    echo "$PHP_PACKAGES" | xargs apt-mark hold >> "$LOG_FILE" 2>&1
    ok "PHP $PHP_VERSION packages held:"
    echo "$PHP_PACKAGES" | while IFS= read -r p; do log "    - $p"; done
else
    info "No PHP $PHP_VERSION packages found to hold"
fi

if [[ -n "$MYSQL_PACKAGES" ]]; then
    echo "$MYSQL_PACKAGES" | xargs apt-mark hold >> "$LOG_FILE" 2>&1
    ok "MySQL/MariaDB packages held:"
    echo "$MYSQL_PACKAGES" | while IFS= read -r p; do log "    - $p"; done
else
    info "No MySQL/MariaDB packages found to hold"
fi

log ""
log "  All currently held packages:"
apt-mark showhold 2>/dev/null | while IFS= read -r p; do log "    * $p"; done

# =====================================================================
# PACKAGE UPGRADE
# =====================================================================

section "UPGRADING PACKAGES"

run_cmd "apt upgrade (held packages protected)" \
    env DEBIAN_FRONTEND=noninteractive \
    apt "${APT_OPTIONS[@]}" upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

# full-upgrade intentionally omitted:
# it can remove packages to resolve dependencies — too destructive on live servers
info "full-upgrade intentionally skipped (unsafe for production)"

# =====================================================================
# POST-UPGRADE SERVICE VERIFICATION
# =====================================================================

section "VERIFYING SERVICES AFTER UPGRADE"

verify_service() {
    local svc="$1"

    if ! systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
        info "$svc not found on this system — skipping"
        return 0
    fi

    if systemctl is-active --quiet "$svc"; then
        ok "$svc is healthy"
        return 0
    fi

    warn "$svc went down after upgrade — attempting recovery"

    if systemctl restart "$svc" >> "$LOG_FILE" 2>&1; then
        # Retry loop: up to 5 × 2s = 10 seconds to come back up
        local recovered=false
        for i in 1 2 3 4 5; do
            sleep 2
            if systemctl is-active --quiet "$svc"; then
                ok "$svc recovered (attempt $i)"
                recovered=true
                break
            fi
            info "  Waiting for $svc... (attempt $i/5)"
        done
        if [[ "$recovered" == "false" ]]; then
            fail "$svc did not recover after 10 seconds — IMMEDIATE ATTENTION REQUIRED"
        fi
    else
        fail "$svc restart command failed — IMMEDIATE ATTENTION REQUIRED"
    fi
}

verify_service "$MYSQL_SERVICE"
verify_service "$WEB_SERVICE"
verify_service "$PHP_FPM"

# =====================================================================
# POST-UPGRADE WEBSITE CHECK
# =====================================================================

section "WEBSITE HEALTH CHECK (POST-UPGRADE)"
http_check "Post-upgrade"

# =====================================================================
# PACKAGE CLEANUP
# =====================================================================

section "PACKAGE CLEANUP"

run_cmd "Fixing broken packages"      apt --fix-broken install -y
run_cmd "Configuring pending packages" dpkg --configure -a
run_cmd "Cleaning apt cache"           apt clean

# Autoremove: show what would be removed, but don't act automatically
log ""
info "Packages eligible for autoremove (dry-run — not removed automatically):"
apt autoremove --purge -s 2>/dev/null | grep "^Remv" \
    | while IFS= read -r line; do log "    $line"; done || true

log ""
echo -e "  ${YELLOW}To remove these packages, run:  sudo apt autoremove --purge${NC}"
info "Autoremove skipped by default for production safety"

# =====================================================================
# JOURNAL CLEANUP
# =====================================================================

section "JOURNAL CLEANUP"
run_cmd "Vacuuming journals (retain: $JOURNAL_RETENTION)" \
    journalctl --vacuum-time="$JOURNAL_RETENTION"

# =====================================================================
# SNAP CLEANUP
# =====================================================================

section "SNAP CLEANUP"

if command -v snap >/dev/null 2>&1; then
    snap set system refresh.retain=2 >> "$LOG_FILE" 2>&1 || true

    SNAP_REMOVED=0
    SNAP_FAILED=0

    while read -r snapname revision; do
        [[ -z "${snapname:-}" ]] && continue
        info "Removing disabled snap: $snapname (rev $revision)"
        if snap remove "$snapname" --revision="$revision" >> "$LOG_FILE" 2>&1; then
            ok "  Removed $snapname rev $revision"
            SNAP_REMOVED=$((SNAP_REMOVED+1))
        else
            warn "  Failed to remove $snapname rev $revision"
            SNAP_FAILED=$((SNAP_FAILED+1))
        fi
    done < <(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')

    ok "Snap cleanup: ${SNAP_REMOVED} removed, ${SNAP_FAILED} failed"
else
    info "Snap not installed — skipping"
fi

# =====================================================================
# REBOOT CHECK
# =====================================================================

section "REBOOT STATUS"

if [[ -f /var/run/reboot-required ]]; then
    warn "System reboot is required"
    warn "DO NOT reboot automatically on a live server."
    warn "Schedule a maintenance window and reboot manually."
    log ""

    if [[ -f /var/run/reboot-required.pkgs ]]; then
        log "  Packages that triggered the reboot requirement:"
        while IFS= read -r pkg; do
            log "    - $pkg"
        done < /var/run/reboot-required.pkgs
    fi
else
    ok "No reboot required"
fi

# =====================================================================
# FINAL DISK REPORT
# =====================================================================

section "FINAL DISK REPORT"
log ""
log "  Filesystem usage:"
df -h | tee -a "$LOG_FILE"
log ""
log "  Top 15 largest directories in /var:"
du -xh /var --max-depth=1 2>/dev/null | sort -hr | head -15 | tee -a "$LOG_FILE"

# =====================================================================
# FINAL SERVICE STATUS
# =====================================================================

section "FINAL SERVICE STATUS"

for svc in "$MYSQL_SERVICE" "$WEB_SERVICE" "$PHP_FPM"; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
        if systemctl is-active --quiet "$svc"; then
            ok "$svc  →  RUNNING"
        else
            fail "$svc  →  DOWN  ← action required"
        fi
    fi
done

# =====================================================================
# FINAL WEBSITE CHECK
# =====================================================================

section "WEBSITE HEALTH CHECK (FINAL)"
http_check "Final"

# =====================================================================
# FOOTER
# =====================================================================

END_DATE=$(date +"%Y-%m-%d %H:%M:%S")

section "MAINTENANCE COMPLETE"

log "  Started  : $START_DATE"
log "  Finished : $END_DATE"
log ""

if [[ "$ERRORS" -eq 0 && "$WARNINGS" -eq 0 ]]; then
    ok  "All steps completed cleanly — no errors, no warnings"
elif [[ "$ERRORS" -eq 0 ]]; then
    warn "Completed with 0 errors and $WARNINGS warning(s) — review above"
else
    fail "Completed with $ERRORS error(s) and $WARNINGS warning(s) — review above"
fi

log ""
log "  Full log: $LOG_FILE"

exit 0
