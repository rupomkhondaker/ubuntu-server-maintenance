# 🛡️ Enterprise Ubuntu Server Maintenance Script

A production-safe, zero-surprise maintenance script for Ubuntu servers running **PHP 7.4**, **MySQL/MariaDB**, and **Nginx/Apache**. Built for live VPS environments where downtime is not an option.

![Ubuntu](https://img.shields.io/badge/Ubuntu-18.04%20%7C%2020.04%20%7C%2022.04%20%7C%2024.04-E95420?style=flat&logo=ubuntu&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-5.0%2B-4EAA25?style=flat&logo=gnubash&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue?style=flat)
![Version](https://img.shields.io/badge/Version-2.0-informational?style=flat)

---

## 📋 Table of Contents

- [What It Does](#-what-it-does)
- [What It Never Does](#-what-it-never-does)
- [How It Works](#-how-it-works)
- [Requirements](#-requirements)
- [Installation](#-installation)
- [Configuration](#️-configuration)
- [How to Run](#-how-to-run)
- [Scheduled Runs with Cron](#-scheduled-runs-with-cron)
- [Log Files](#-log-files)
- [Backups](#-backups)
- [Understanding the Output](#-understanding-the-output)
- [Troubleshooting](#-troubleshooting)

---

## ✅ What It Does

| Step | Description |
|------|-------------|
| **Disk check** | Verifies `/var` has enough free space before starting |
| **Pre-flight** | Confirms MySQL, PHP-FPM, and Nginx/Apache are all running *before* touching anything |
| **HTTP check** | Hits your site URL and verifies it returns a healthy HTTP status code |
| **MySQL backup** | Full `mysqldump` with size validation — rejects empty/corrupt dumps |
| **Config backup** | Archives `/etc/nginx`, `/etc/php`, `/etc/mysql`, etc. — skips dirs that don't exist |
| **Backup cleanup** | Removes backups older than `BACKUP_RETAIN_DAYS` days automatically |
| **Package preview** | Shows everything that would be upgraded and warns about PHP/MySQL in the list |
| **Confirmation** | Waits for your explicit `y` before making any changes |
| **Package hold** | Pins all `php7.4-*` and `mysql-*` packages so they can never be auto-upgraded |
| **Safe upgrade** | Runs `apt upgrade` only — never `full-upgrade` |
| **Service recovery** | If a service goes down after upgrade, restarts it and retries for up to 10 seconds |
| **Cleanup** | Fixes broken packages, clears apt cache, shows autoremove candidates (dry-run only) |
| **Journal cleanup** | Removes systemd journal logs older than 7 days |
| **Snap cleanup** | Removes disabled old snap revisions |
| **Reboot check** | Tells you if a reboot is needed — never reboots automatically |
| **Final report** | Disk usage, top directories, service status, and HTTP check |

---

## 🚫 What It Never Does

- ❌ Runs `full-upgrade` (can remove packages to resolve deps — too destructive)
- ❌ Auto-reboots the server
- ❌ Upgrades your PHP version
- ❌ Runs `autoremove` without showing you what it would remove first
- ❌ Proceeds if any service is already down before it starts

---

## 🔄 How It Works

```
START
  │
  ├─► Lock file check (prevents concurrent runs)
  ├─► Root check
  ├─► Disk space check (/var must have ≥ 1 GB free)
  ├─► Pre-flight: MySQL + Web Server + PHP-FPM must all be UP
  ├─► HTTP health check (pre-maintenance baseline)
  │
  ├─► BACKUPS
  │     ├─► Old backups cleanup (> 7 days)
  │     ├─► MySQL dump → /backup/mysql/mysql-all-YYYY-MM-DD-HHMM.sql.gz
  │     └─► Config tar  → /backup/configs/configs-YYYY-MM-DD-HHMM.tar.gz
  │
  ├─► apt update → show upgradable packages → ask confirmation
  │
  ├─► HOLD php7.4-* and mysql-* packages (apt-mark hold)
  ├─► apt upgrade (held packages are protected)
  │
  ├─► Post-upgrade: verify services, auto-recover if down
  ├─► HTTP health check (post-upgrade)
  │
  ├─► apt --fix-broken, dpkg --configure -a, apt clean
  ├─► journalctl vacuum
  ├─► snap cleanup
  │
  ├─► Reboot check (warns only, never reboots)
  └─► Final: disk report + service status + HTTP check + summary
```

---

## 📦 Requirements

- Ubuntu 18.04, 20.04, 22.04, or 24.04
- `bash` 5.0+
- `curl` (for HTTP health checks)
- `mysqldump` (for database backups — installed with `mysql-client`)
- Root / sudo access
- At least **1 GB free** on `/var`
- At least **512 MB free** in your backup directory

---

## 🚀 Installation

```bash
# 1. Clone the repository
git clone https://github.com/yourusername/server-maintenance.git
cd server-maintenance

# 2. Make the script executable
chmod +x server-maintenance-enterprise.sh

# 3. Create the backup directory
sudo mkdir -p /backup/mysql /backup/configs

# 4. Edit the configuration (see next section)
nano server-maintenance-enterprise.sh
```

---

## ⚙️ Configuration

All configuration is at the top of the script in a clearly marked section. Edit these variables before your first run:

```bash
# =====================================================================
# CONFIGURATION  — edit this section for your server
# =====================================================================

PHP_VERSION="7.4"               # Your PHP version
MYSQL_SERVICE="mysql"           # "mysql" or "mariadb"
WEB_SERVICE="nginx"             # "nginx" or "apache2"

SITE_CHECK_URL="http://localhost"   # Your site URL (blank = skip)
SITE_EXPECTED_TEXT=""               # Optional: text that must appear in response body

BACKUP_DIR="/backup"            # Where to store backups
BACKUP_RETAIN_DAYS=7            # Days to keep old backups (0 = forever)

MIN_FREE_MB=1024                # Minimum free MB on /var to proceed
MIN_BACKUP_FREE_MB=512          # Minimum free MB in BACKUP_DIR before MySQL dump

JOURNAL_RETENTION="7d"          # How long to keep systemd journal logs
LOG_FILE="/var/log/server-maintenance.log"
```

### Common configuration examples

**Apache + MariaDB server:**
```bash
MYSQL_SERVICE="mariadb"
WEB_SERVICE="apache2"
```

**Check your site returns specific content:**
```bash
SITE_CHECK_URL="https://yourdomain.com"
SITE_EXPECTED_TEXT="Welcome to My App"
```

**Keep backups for 14 days:**
```bash
BACKUP_RETAIN_DAYS=14
```

**Different PHP version:**
```bash
PHP_VERSION="8.1"
```

---

## ▶️ How to Run

### Manual run (recommended first time)

```bash
sudo ./server-maintenance-enterprise.sh
```

The script will:
1. Run all pre-flight checks
2. Show you a list of packages that would be upgraded
3. **Pause and ask for your confirmation** before making any changes
4. Run all maintenance steps with colored output
5. Print a summary of errors and warnings

### Check what would be upgraded without running maintenance

```bash
sudo apt update && apt list --upgradable 2>/dev/null
```

### Verify your PHP and MySQL holds after running

```bash
apt-mark showhold
```

### View the log after a run

```bash
sudo tail -100 /var/log/server-maintenance.log
```

### Follow a run in real time (from another terminal)

```bash
sudo tail -f /var/log/server-maintenance.log
```

---

## ⏰ Scheduled Runs with Cron

> **Important:** Cron runs are non-interactive — the script detects this and skips the confirmation prompt. Make sure you have tested it manually at least once before scheduling.

### Option 1 — Standard crontab (recommended)

Open the root crontab:

```bash
sudo crontab -e
```

Add one of the following lines:

```cron
# Run every Sunday at 2:00 AM
0 2 * * 0 /path/to/server-maintenance-enterprise.sh >> /var/log/server-maintenance-cron.log 2>&1

# Run on the 1st of every month at 3:00 AM
0 3 1 * * /path/to/server-maintenance-enterprise.sh >> /var/log/server-maintenance-cron.log 2>&1

# Run every day at 4:00 AM (aggressive — only for non-critical servers)
0 4 * * * /path/to/server-maintenance-enterprise.sh >> /var/log/server-maintenance-cron.log 2>&1
```

> **Tip:** Choose a time when your traffic is lowest. Check your analytics to find the quietest hour.

### Option 2 — Cron with email notification on failure

First install `mailutils` if not present:

```bash
sudo apt install mailutils -y
```

Then add to your crontab:

```cron
MAILTO="you@yourdomain.com"
0 2 * * 0 /path/to/server-maintenance-enterprise.sh >> /var/log/server-maintenance-cron.log 2>&1
```

Cron will email you the output automatically if the script produces any output (which it always does) — or use `MAILTO` to only get emailed on non-zero exit.

### Option 3 — Systemd timer (modern alternative to cron)

Create a service file:

```bash
sudo nano /etc/systemd/system/server-maintenance.service
```

```ini
[Unit]
Description=Enterprise Server Maintenance
After=network.target mysql.service nginx.service

[Service]
Type=oneshot
ExecStart=/path/to/server-maintenance-enterprise.sh
StandardOutput=append:/var/log/server-maintenance.log
StandardError=append:/var/log/server-maintenance.log
```

Create the timer:

```bash
sudo nano /etc/systemd/system/server-maintenance.timer
```

```ini
[Unit]
Description=Run server maintenance weekly

[Timer]
OnCalendar=Sun 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now server-maintenance.timer

# Verify the timer is active
sudo systemctl list-timers server-maintenance.timer

# Run it immediately to test
sudo systemctl start server-maintenance.service

# Check the result
sudo journalctl -u server-maintenance.service -n 50
```

### Making the script non-interactive for scheduled runs

The confirmation prompt will block cron. To skip it automatically when running unattended, add this check just before the `read` line in the script, or pass an environment variable:

```bash
# Detect non-interactive mode (cron sets no TTY)
if [ ! -t 0 ]; then
    CONFIRM="y"
else
    read -r -p "  Proceed with maintenance? [y/N]: " CONFIRM
fi
```

Or call it with a pre-set answer:

```bash
# In your crontab — pipe 'y' to auto-confirm
echo "y" | sudo /path/to/server-maintenance-enterprise.sh >> /var/log/server-maintenance-cron.log 2>&1
```

---

## 📁 Log Files

| File | Description |
|------|-------------|
| `/var/log/server-maintenance.log` | Main log — all runs appended here |
| `/var/log/server-maintenance-cron.log` | Cron-specific output (if configured above) |
| `/etc/logrotate.d/server-maintenance` | Logrotate config — created automatically on first run |

The logrotate config rotates the main log **monthly**, keeps **6 months** of history, and compresses old logs automatically. No manual cleanup needed.

To view logs:

```bash
# Last 50 lines
sudo tail -50 /var/log/server-maintenance.log

# Search for failures
sudo grep '\[FAIL\]' /var/log/server-maintenance.log

# Search for warnings
sudo grep '\[WARN\]' /var/log/server-maintenance.log

# Show all runs (look for headers)
sudo grep 'MAINTENANCE STARTED' /var/log/server-maintenance.log
```

---

## 💾 Backups

Backups are stored in `/backup` (configurable via `BACKUP_DIR`):

```
/backup/
├── mysql/
│   ├── mysql-all-2025-05-18-0200.sql.gz   ← this week
│   └── mysql-all-2025-05-11-0200.sql.gz   ← last week (auto-deleted after 7 days)
└── configs/
    ├── configs-2025-05-18-0200.tar.gz
    └── configs-2025-05-11-0200.tar.gz
```

### Restore MySQL from backup

```bash
# Decompress
gunzip /backup/mysql/mysql-all-2025-05-18-0200.sql.gz

# Restore
sudo mysql < /backup/mysql/mysql-all-2025-05-18-0200.sql
```

### Restore a config file from backup

```bash
# Extract a single file
sudo tar -xzf /backup/configs/configs-2025-05-18-0200.tar.gz \
    -C / etc/nginx/nginx.conf
```

---

## 🔍 Understanding the Output

```
[ OK ]   Step completed successfully
[INFO]   Informational message — no action needed
[WARN]   Non-critical issue — review recommended
[FAIL]   Something went wrong — review required
```

A typical successful run ends with:

```
=====================================================================
  MAINTENANCE COMPLETE
=====================================================================
  Started  : 2025-05-18 02:00:01
  Finished : 2025-05-18 02:04:37

[ OK ]  All steps completed cleanly — no errors, no warnings
```

A run with warnings ends with:

```
[WARN]  Completed with 0 errors and 2 warning(s) — review above
```

---

## 🔧 Troubleshooting

**Script exits immediately saying "Another process is running"**
```bash
# Check if a stale lock file exists
ls -la /var/run/server-maintenance.lock
# Safe to remove if no maintenance is actually running
sudo rm /var/run/server-maintenance.lock
```

**Pre-flight fails because a service is down**
```bash
# Check what's wrong with the service before running maintenance
sudo systemctl status nginx
sudo journalctl -u nginx -n 30
```

**MySQL backup fails**
```bash
# Verify debian.cnf exists and has correct credentials
sudo cat /etc/mysql/debian.cnf

# Test mysqldump manually
sudo mysqldump --defaults-file=/etc/mysql/debian.cnf \
    --all-databases --single-transaction > /tmp/test.sql
```

**Not enough disk space on /var**
```bash
# Find what's using space
sudo du -xh /var --max-depth=2 | sort -hr | head -20

# Common culprits
sudo journalctl --disk-usage
sudo apt clean
```

**PHP packages not being held**
```bash
# Check which PHP packages are installed
dpkg-query -W -f='${binary:Package}\n' | grep "^php7.4"

# Manually hold them
sudo apt-mark hold php7.4 php7.4-fpm php7.4-mysql php7.4-cli

# Verify
apt-mark showhold
```

---

## 📄 License

MIT License — free to use, modify, and distribute.

---

## 🤝 Contributing

Pull requests welcome. Please test against a staging server before submitting changes that affect upgrade or backup behaviour.
