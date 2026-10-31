#!/usr/bin/env bash
#
# FileBrowser Quantum setup toolkit for Debian 13 (trixie)
# A small web file manager with share links, behind nginx.
#
# Usage:
#   sudo bash filebrowser-setup.sh                # interactive menu
#   sudo bash filebrowser-setup.sh <action>       # run one action directly
#   sudo bash filebrowser-setup.sh <action> -y    # ...without questions (defaults / env vars)
#
# Actions:
#   install    Install FileBrowser Quantum + nginx
#   check      Health check: version, drives, services, memory, security
#   update     Update FileBrowser to the latest stable release (rolls back on failure)
#   password   Reset a user's password (or create a user)
#   swap       Add, resize or remove a swap file
#   fail2ban   Block brute-force attacks on SSH and FileBrowser logins
#   duckdns    Keep a DuckDNS name pointed at this server (set up or check status)
#   https      HTTPS with Let's Encrypt (set up, or check status and fix issues)
#
# Install settings can be preset as environment variables (they become the
# default answers): DATA_DIR, PUBLIC_URL, FB_PORT, FB_VERSION
#
# Log: /var/log/filebrowser-setup.log
#
set -Eeuo pipefail

REPO="gtsteffaniak/filebrowser"
FALLBACK_TAG="v2.0.2-stable"
FB_BIN="/usr/local/bin/filebrowser"
FB_HOME="/opt/filebrowser"
FB_CONFIG="$FB_HOME/config.yaml"
FB_DB="$FB_HOME/filebrowser.sqlite"
FB_USER="filebrowser"
FB_UNIT="/etc/systemd/system/filebrowser.service"
NGX_SITE="/etc/nginx/sites-available/filebrowser"
F2B_FILTER="/etc/fail2ban/filter.d/filebrowser.conf"
F2B_JAIL="/etc/fail2ban/jail.local"
SWAPFILE="/swapfile"
SWAPPINESS_CONF="/etc/sysctl.d/99-swappiness.conf"
LOG_FILE="/var/log/filebrowser-setup.log"
MARKER="# Managed by filebrowser-setup.sh"
DUCK_CONF="/etc/duckdns.conf"
DUCK_BIN="/usr/local/bin/duckdns-update"
DUCK_STATE="/var/lib/duckdns/last"
DUCK_SVC="/etc/systemd/system/duckdns-update.service"
DUCK_TIMER="/etc/systemd/system/duckdns-update.timer"

# Optional preset answers from the environment
ENV_DATA_DIR="${DATA_DIR:-}"
ENV_PUBLIC_URL="${PUBLIC_URL:-}"
ENV_FB_PORT="${FB_PORT:-}"
ENV_FB_VERSION="${FB_VERSION:-}"

usage() { awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$0"; }

ASSUME_YES=no
ACTION=""
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=yes ;;
    -h|--help|help) usage; exit 0 ;;
    install|check|update|password|swap|fail2ban|duckdns|https) ACTION="$arg" ;;
    *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
  esac
done

# =================================================================== helpers ==
if [[ -t 1 ]]; then
  C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_B=$'\033[1m'; C_D=$'\033[2m'; C_0=$'\033[0m'
else
  C_G=""; C_Y=""; C_R=""; C_B=""; C_D=""; C_0=""
fi

CURRENT_STEP="starting up"
step() { CURRENT_STEP="$*"; echo -e "\n${C_G}==> $*${C_0}"; }
info() { echo "    $*"; }
warn() { echo -e "${C_Y}!!  $*${C_0}"; }
die()  { echo -e "\n${C_R}ERROR: $*${C_0}" >&2; exit 1; }

CHK_BAD=0; CHK_WARN=0
c_ok()   { echo -e "    ${C_G}✓${C_0} $*"; }
c_warn() { echo -e "    ${C_Y}!${C_0} $*"; CHK_WARN=$((CHK_WARN + 1)); }
c_bad()  { echo -e "    ${C_R}✗${C_0} $*"; CHK_BAD=$((CHK_BAD + 1)); }
c_info() { echo -e "    ${C_D}·${C_0} $*"; }

on_error() {
  local code=$? line=$1 cmd=$2
  trap - ERR
  echo -e "\n${C_R}======================================================${C_0}" >&2
  echo -e "${C_R} Failed during: ${CURRENT_STEP}${C_0}" >&2
  echo -e "${C_R} Command:  ${cmd}${C_0}" >&2
  echo -e "${C_R} Line ${line}, exit code ${code}${C_0}" >&2
  echo -e "${C_R}======================================================${C_0}" >&2
  echo "  Full log: $LOG_FILE" >&2
  echo "  Fix the problem and run it again; finished steps are skipped." >&2
  exit "$code"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

ask() {
  local q="$1" def="$2" ans=""
  if [[ "$ASSUME_YES" == yes ]]; then echo "$def"; return 0; fi
  printf '  %s [%s]: ' "$q" "$def" >/dev/tty
  IFS= read -r ans </dev/tty || true
  echo "${ans:-$def}"
}
ask_yn() {
  local q="$1" def="$2" ans hint
  if [[ "$def" == yes ]]; then hint="Y/n"; else hint="y/N"; fi
  if [[ "$ASSUME_YES" == yes ]]; then echo "$def"; return 0; fi
  while true; do
    printf '  %s [%s]: ' "$q" "$hint" >/dev/tty
    IFS= read -r ans </dev/tty || true
    ans="${ans:-$def}"
    case "${ans,,}" in
      y|yes) echo yes; return 0 ;;
      n|no)  echo no;  return 0 ;;
      *) echo "    Please answer y or n." >/dev/tty ;;
    esac
  done
}
# ask_secret "Prompt" -> echoes the typed value (not shown on screen)
ask_secret() {
  local q="$1" ans=""
  printf '  %s: ' "$q" >/dev/tty
  IFS= read -rs ans </dev/tty || true
  echo >/dev/tty
  echo "$ans"
}
pause() {
  if [[ "$ASSUME_YES" == yes ]]; then return 0; fi
  printf '\n  Press Enter to return to the menu...' >/dev/tty
  read -r _ </dev/tty || true
}

ram_mb() { awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }
rec_swap() { if (( $(ram_mb) < 2048 )); then echo 2G; else echo 1G; fi; }
server_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

fb_installed() { [[ -x "$FB_BIN" && -f "$FB_CONFIG" ]]; }
require_fb() { fb_installed || die "FileBrowser isn't installed yet. Run the install first."; }
fb_version() {
  if [[ -x "$FB_BIN" ]]; then
    (cd /tmp && "$FB_BIN" version 2>/dev/null | grep -oE 'v[0-9][0-9.]*-[a-z]+' | head -1) || true
  fi
}

# Simple readers for the config this script writes
cfg_source_path() { sed -nE 's/^[[:space:]]*- path:[[:space:]]*"?([^"#]*[^"#[:space:]])"?.*/\1/p' "$FB_CONFIG" 2>/dev/null | head -1; }
cfg_value() { sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"#]*[^\"#[:space:]])?\"?.*/\1/p" "$FB_CONFIG" 2>/dev/null | head -1; }
cfg_port() { local p; p="$(cfg_value port)"; echo "${p:-8080}"; }

fb_health() { curl -fsS --max-time 5 "http://127.0.0.1:$(cfg_port)/api/health" >/dev/null 2>&1; }
wait_for_fb() {
  for _ in $(seq 1 30); do
    if fb_health; then return 0; fi
    sleep 1
  done
  return 1
}

fb_arch_asset() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "linux-amd64-filebrowser" ;;
    aarch64|arm64) echo "linux-arm64-filebrowser" ;;
    armv7l)        echo "linux-armv7-filebrowser" ;;
    armv6l)        echo "linux-armv6-filebrowser" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

# Finds the newest *-stable release tag (never betas)
latest_stable_tag() {
  local tag=""
  tag="$(curl -fsSL -o /dev/null -w '%{url_effective}' --max-time 20 "https://github.com/${REPO}/releases/latest" 2>/dev/null \
         | grep -oE 'v[0-9][0-9.]*-stable$' || true)"
  if [[ -z "$tag" ]]; then
    tag="$(curl -fsS --max-time 20 "https://api.github.com/repos/${REPO}/releases?per_page=30" 2>/dev/null \
           | grep -oE '"tag_name": *"v[0-9][0-9.]*-stable"' | head -1 | grep -oE 'v[0-9][0-9.]*-stable' || true)"
  fi
  if [[ -z "$tag" ]] && command -v git >/dev/null 2>&1; then
    tag="$(git ls-remote --tags "https://github.com/${REPO}.git" 2>/dev/null \
           | grep -oE 'v[0-9][0-9.]*-stable$' | sort -V | tail -1 || true)"
  fi
  echo "$tag"
}

# download_fb <tag> <dest> : downloads the binary and checks that it runs
download_fb() {
  local tag="$1" dest="$2" asset url got
  asset="$(fb_arch_asset)"
  url="https://github.com/${REPO}/releases/download/${tag}/${asset}"
  info "Downloading $asset ($tag)..."
  curl -fL --progress-bar --retry 3 -o "$dest" "$url" || die "Download failed: $url"
  chmod 755 "$dest"
  got="$(cd /tmp && "$dest" version 2>/dev/null | grep -oE 'v[0-9][0-9.]*-[a-z]+' | head -1 || true)"
  [[ -n "$got" ]] || die "The downloaded file doesn't run as FileBrowser (corrupt download?)"
  info "Downloaded binary reports version $got"
}

# path_info /some/path -> sets PI_DEV PI_FS PI_MNT PI_FREE PI_DISK PI_ROTA
path_info() {
  local p="$1"
  while [[ ! -e "$p" ]]; do p="$(dirname "$p")"; done
  PI_DEV="$(findmnt -n -o SOURCE --target "$p" 2>/dev/null || echo "?")"
  PI_FS="$(findmnt -n -o FSTYPE --target "$p" 2>/dev/null || echo "?")"
  PI_MNT="$(findmnt -n -o TARGET --target "$p" 2>/dev/null || echo "?")"
  PI_FREE="$(df -Ph "$p" 2>/dev/null | awk 'NR==2 {print $4}')"
  PI_DISK="$(lsblk -no PKNAME "$PI_DEV" 2>/dev/null | head -1 || true)"
  if [[ -z "$PI_DISK" ]]; then PI_DISK="$(basename "$PI_DEV")"; fi
  PI_ROTA="$(lsblk -dno ROTA "/dev/$PI_DISK" 2>/dev/null | tr -d ' ' || true)"
}
rota_text() { case "$1" in 1) echo "reports as spinning disk" ;; 0) echo "reports as SSD" ;; *) echo "type unknown" ;; esac; }

nginx_test_reload() {
  local err
  if err="$(nginx -t 2>&1)"; then systemctl reload nginx; return 0; fi
  echo "$err"
  return 1
}

# The nginx site that serves FileBrowser, found by what it proxies to (whatever the file is called)
ngx_site() {
  local f port
  port="$(cfg_port)"
  for f in /etc/nginx/sites-enabled/*; do
    [[ -e "$f" ]] || continue
    if grep -q "proxy_pass http://127.0.0.1:${port}" "$f" 2>/dev/null; then readlink -f "$f"; return 0; fi
  done
  echo "$NGX_SITE"
}
https_on() { grep -q "managed by Certbot" "$1" 2>/dev/null; }
site_domain() { sed -nE 's/^[[:space:]]*server_name[[:space:]]+([^;[:space:]]+).*/\1/p' "$1" 2>/dev/null | grep -vx '_' | head -1 || true; }

# cert_info <site> -> sets CERT_END CERT_DAYS (returns 1 if there's no certificate)
cert_info() {
  local f end
  CERT_END=""; CERT_DAYS=""
  f="$(sed -nE 's/^[[:space:]]*ssl_certificate[[:space:]]+([^;[:space:]]+);.*/\1/p' "$1" 2>/dev/null | head -1 || true)"
  if [[ -z "$f" || ! -f "$f" ]] || ! command -v openssl >/dev/null 2>&1; then return 1; fi
  end="$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2 || true)"
  if [[ -z "$end" ]]; then return 1; fi
  CERT_DAYS=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
  CERT_END="$(date -d "$end" +%Y-%m-%d)"
}

# dns_check <domain> -> sets DNS_IPS; returns 0 if it points at this server, 1 if elsewhere, 2 if not resolving
dns_check() {
  local ip mine
  DNS_IPS="$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' ' - || true)"
  if [[ -z "$DNS_IPS" ]]; then return 2; fi
  mine=" $(hostname -I 2>/dev/null) $(duck_last_ip) "
  for ip in $DNS_IPS; do
    if [[ "$mine" == *" $ip "* ]]; then return 0; fi
  done
  return 1
}

# DuckDNS helpers
duck_configured() { [[ -f "$DUCK_CONF" ]]; }
duck_domains() { sed -nE 's/^DUCKDNS_DOMAINS="?([^"]*)"?.*/\1/p' "$DUCK_CONF" 2>/dev/null | head -1 || true; }
duck_first_fqdn() {
  local d
  d="$(duck_domains)"
  if [[ -z "$d" ]] && duck_external; then d="$EXT_DOMAINS"; fi
  d="${d%%,*}"
  if [[ -n "$d" ]]; then echo "${d}.duckdns.org"; fi
}
# --- DuckDNS updaters set up outside this script (e.g. duckdns.org's duck.sh + cron)
EXT_LINE=""; EXT_SCRIPT=""; EXT_LOG=""; EXT_DOMAINS=""; EXT_TOKEN=""
duck_external() {
  local home src url
  EXT_LINE=""; EXT_SCRIPT=""; EXT_LOG=""; EXT_DOMAINS=""; EXT_TOKEN=""
  command -v crontab >/dev/null 2>&1 || return 1
  EXT_LINE="$(crontab -l 2>/dev/null | grep -vE '^[[:space:]]*#' | grep -E 'duckdns\.org/update|duck[^[:space:]/]*\.sh' | head -1 || true)"
  if [[ -z "$EXT_LINE" ]]; then return 1; fi
  home="$(getent passwd root | cut -d: -f6)"
  EXT_SCRIPT="$(grep -oE '[^[:space:]]*duck[^[:space:]]*\.sh' <<<"$EXT_LINE" | head -1 || true)"
  EXT_SCRIPT="${EXT_SCRIPT/#\~/$home}"
  if [[ -n "$EXT_SCRIPT" && -r "$EXT_SCRIPT" ]]; then src="$(cat "$EXT_SCRIPT")"; else src="$EXT_LINE"; fi
  url="$(grep -oE 'duckdns\.org/update\?[^"'"'"'[:space:]]*' <<<"$src" | head -1 || true)"
  EXT_DOMAINS="$(sed -nE 's/.*[?&]domains=([^&]*).*/\1/p' <<<"$url")"
  EXT_TOKEN="$(sed -nE 's/.*[?&]token=([^&]*).*/\1/p' <<<"$url")"
  EXT_LOG="$(grep -oE '\-o[[:space:]]+[^[:space:]]+' <<<"$src" | head -1 | awk '{print $2}' || true)"
  EXT_LOG="${EXT_LOG/#\~/$home}"
  if [[ -z "$EXT_LOG" && -n "$EXT_SCRIPT" ]]; then EXT_LOG="$(dirname "$EXT_SCRIPT")/duck.log"; fi
  return 0
}
duck_external_lines() {
  local res age d st=0
  c_info "Updated by a cron job that this script didn't set up:"
  c_info "  $EXT_LINE"
  if [[ -n "$EXT_DOMAINS" ]]; then c_info "Names: $(sed 's/,/.duckdns.org, /g' <<<"$EXT_DOMAINS").duckdns.org"; fi
  if [[ -n "$EXT_LOG" && -f "$EXT_LOG" ]]; then
    res="$(tr -d '[:space:]' < "$EXT_LOG")"
    age=$(( ( $(date +%s) - $(stat -c %Y "$EXT_LOG") ) / 60 ))
    if [[ "$res" == OK* ]]; then
      if (( age > 15 )); then c_warn "Last successful update was $age minutes ago"; else c_ok "Last update OK, $age min ago"; fi
    else
      c_bad "Last update returned '${res:-nothing}' ($age min ago); check the token and subdomain"
    fi
  else
    c_info "No update log found, so the last result is unknown"
  fi
  if [[ -n "$EXT_DOMAINS" ]]; then
    d="${EXT_DOMAINS%%,*}.duckdns.org"
    dns_check "$d" || st=$?
    case "$st" in
      0) c_ok "$d resolves to this server ($DNS_IPS)" ;;
      2) c_warn "$d doesn't resolve" ;;
      *) c_warn "$d resolves to $DNS_IPS, not this server" ;;
    esac
  fi
}

duck_last() { cat "$DUCK_STATE" 2>/dev/null || true; }           # "YYYY-MM-DD HH:MM:SS OK 1.2.3.4 UPDATED"
duck_last_ip() { duck_last | awk '$3 == "OK" {print $4}'; }
duck_last_age_min() {
  local t
  t="$(duck_last | awk '{print $1" "$2}')"
  if [[ -n "$t" ]]; then echo $(( ( $(date +%s) - $(date -d "$t" +%s) ) / 60 )); fi
}

# ================================================================== install ==
do_install() {
  local DEF_DATA DEF_URL DATA_DIR PUBLIC_URL_V PORT TAG FFMPEG=no ALREADY=no ip PORT80 tmpbin
  # shellcheck disable=SC1091
  . /etc/os-release
  step "Install FileBrowser Quantum"
  [[ "${VERSION_CODENAME:-}" == "trixie" ]] || warn "Written for Debian 13 (trixie); you're on ${PRETTY_NAME:-unknown}."

  if fb_installed; then
    ALREADY=yes
    warn "FileBrowser is already installed ($(fb_version))."
    warn "Running this again re-applies the nginx and service setup. Your config,"
    warn "users and shares are kept. (Use 'update' to get a newer version.)"
    if [[ "$(ask_yn "Continue?" no)" != yes ]]; then info "Cancelled."; return 0; fi
  fi

  ip="$(server_ip)"
  echo
  if [[ "$ASSUME_YES" == no ]]; then info "Press Enter to accept the value in [brackets]."; echo; fi

  if [[ "$ALREADY" == yes ]]; then
    DATA_DIR="$(cfg_source_path)"
    PUBLIC_URL_V="$(cfg_value externalUrl)"
    PORT="$(cfg_port)"
    info "Files folder (from config): $DATA_DIR"
  else
    if mountpoint -q /mnt/data 2>/dev/null; then DEF_DATA="/mnt/data/files"; else DEF_DATA="/srv/files"; fi
    DEF_DATA="${ENV_DATA_DIR:-$DEF_DATA}"
    while true; do
      DATA_DIR="$(ask "Folder to store and share files in" "$DEF_DATA")"
      DATA_DIR="${DATA_DIR%/}"
      if [[ "$DATA_DIR" != /* ]]; then
        warn "Must be a full path starting with /"
      elif [[ "$DATA_DIR" == "/" || "$DATA_DIR" == /var* || "$DATA_DIR" == "$FB_HOME"* ]]; then
        warn "Don't use /, anything under /var, or $FB_HOME. Pick a dedicated folder."
      else
        break
      fi
      if [[ "$ASSUME_YES" == yes ]]; then die "Invalid DATA_DIR: '$DATA_DIR'"; fi
    done

    DEF_URL="${ENV_PUBLIC_URL:-http://$ip}"
    while true; do
      PUBLIC_URL_V="$(ask "Address used in share links" "$DEF_URL")"
      PUBLIC_URL_V="${PUBLIC_URL_V%/}"
      if [[ "$PUBLIC_URL_V" =~ ^https?://[^/[:space:]]+$ ]]; then break; fi
      warn "Use the form http://1.2.3.4 or https://files.example.com"
      if [[ "$ASSUME_YES" == yes ]]; then die "Invalid PUBLIC_URL: '$PUBLIC_URL_V'"; fi
    done

    while true; do
      PORT="$(ask "Internal port for FileBrowser (only nginx talks to it)" "${ENV_FB_PORT:-8080}")"
      if [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT > 1024 && PORT < 65536 && PORT != 8443 )); then break; fi
      warn "Pick a port between 1025 and 65535."
      if [[ "$ASSUME_YES" == yes ]]; then die "Invalid FB_PORT: '$PORT'"; fi
    done

    echo
    info "ffmpeg adds video thumbnails and previews (around 300 MB of packages)."
    FFMPEG="$(ask_yn "Install ffmpeg?" no)"
  fi

  # ---- pre-flight
  step "Checking the system"
  CHK_BAD=0
  path_info "$DATA_DIR"
  if [[ "$DATA_DIR" == /mnt/* || "$DATA_DIR" == /media/* ]] && [[ "$PI_MNT" == "/" ]]; then
    c_bad "$DATA_DIR is on the system disk; your data drive isn't mounted (check: df -h $(dirname "$DATA_DIR"))"
  else
    c_ok "Files folder on $PI_DEV ($PI_FS, $PI_FREE free, $(rota_text "$PI_ROTA"))"
  fi
  case "$PI_FS" in
    vfat|exfat|ntfs|ntfs3|fuseblk) c_bad "That drive is $PI_FS, which doesn't support Linux permissions. Reformat it as ext4." ;;
  esac
  if (( $(df -Pk / | awk 'NR==2 {print $4}') < 524288 )); then c_bad "Less than 512 MB free on the system disk"
  else c_ok "System disk: $(df -Ph / | awk 'NR==2 {print $4}') free"; fi
  c_ok "$(ram_mb) MB RAM"
  if command -v ss >/dev/null 2>&1; then
    PORT80="$(ss -ltnpH 'sport = :80' 2>/dev/null | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2 || true)"
    if [[ -n "$PORT80" && "$PORT80" != "nginx" ]]; then c_bad "Port 80 is already used by '$PORT80'"; else c_ok "Port 80 available"; fi
    if [[ "$ALREADY" == no ]] && ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; then c_bad "Port $PORT is already in use; pick another"; fi
  fi
  if getent hosts github.com >/dev/null; then c_ok "Internet/DNS working"; else c_bad "Can't resolve github.com; check the server's internet/DNS"; fi
  if (( CHK_BAD > 0 )); then die "Fix the problems above and try again."; fi

  if [[ "$ALREADY" == no ]]; then
    TAG="${ENV_FB_VERSION}"
    if [[ -z "$TAG" ]]; then
      TAG="$(latest_stable_tag)"
      if [[ -z "$TAG" ]]; then warn "Couldn't look up the latest release; using $FALLBACK_TAG"; TAG="$FALLBACK_TAG"; fi
    fi
  else
    TAG="$(fb_version)"
  fi

  echo
  echo -e "${C_B}  Ready to install with these settings:${C_0}"
  echo "    FileBrowser:    $TAG"
  echo "    Files folder:   $DATA_DIR  (on $PI_DEV)"
  echo "    Share links:    $PUBLIC_URL_V"
  echo "    App data:       $FB_HOME  (config, database, thumbnails)"
  echo "    Web access:     nginx on port 80 → FileBrowser on 127.0.0.1:$PORT"
  echo
  if [[ "$(ask_yn "Continue?" yes)" != yes ]]; then info "Cancelled; nothing was changed."; return 0; fi

  # ---- packages
  step "Installing packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q nginx curl ca-certificates
  if [[ "$FFMPEG" == yes ]]; then apt-get install -y -q ffmpeg; fi

  # ---- user and folders
  step "Creating the service user and folders"
  if ! id "$FB_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$FB_HOME" --no-create-home --shell /usr/sbin/nologin "$FB_USER"
    info "Created system user '$FB_USER'"
  fi
  mkdir -p "$FB_HOME/cache"
  chown -R "$FB_USER:$FB_USER" "$FB_HOME"
  chmod 750 "$FB_HOME"
  if [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]] && [[ "$(stat -c %U "$DATA_DIR")" != "$FB_USER" ]]; then
    if [[ "$(ask_yn "$DATA_DIR already has files. Make '$FB_USER' their owner so it can manage them?" yes)" == yes ]]; then
      chown -R "$FB_USER:$FB_USER" "$DATA_DIR"
    else
      warn "FileBrowser may not be able to change or delete existing files there."
    fi
  else
    mkdir -p "$DATA_DIR"
    chown "$FB_USER:$FB_USER" "$DATA_DIR"
  fi
  sudo -u "$FB_USER" test -w "$DATA_DIR" || die "'$FB_USER' can't write to $DATA_DIR"
  info "$DATA_DIR is writable by $FB_USER"

  # ---- binary
  if [[ "$ALREADY" == no || ! -x "$FB_BIN" ]]; then
    step "Downloading FileBrowser $TAG"
    tmpbin="$(mktemp)"
    download_fb "$TAG" "$tmpbin"
    install -m 755 "$tmpbin" "$FB_BIN"
    rm -f "$tmpbin"
  else
    step "FileBrowser binary already installed ($(fb_version)), keeping it"
  fi

  # ---- config
  step "Writing the config"
  if [[ -f "$FB_CONFIG" ]]; then
    info "Config already exists at $FB_CONFIG; leaving it alone"
  else
    {
      echo "$MARKER"
      echo "# Full option reference: https://github.com/${REPO}/blob/main/frontend/public/config.generated.yaml"
      echo "server:"
      echo "  sources:"
      echo "    - path: \"$DATA_DIR\""
      echo "      name: \"Files\""
      echo "      config:"
      echo "        defaultEnabled: true"
      echo "  cacheDir: \"$FB_HOME/cache\""
      echo "  database:"
      echo "    path: \"$FB_DB\""
      echo "  logging:"
      echo "    - levels: \"info|warning|error\""
      echo "      noColors: true"
      echo "http:"
      echo "  port: $PORT"
      echo "  listen: \"127.0.0.1\""
      echo "  externalUrl: \"$PUBLIC_URL_V\""
      echo "  trustProxyHeaders: true"
      echo "auth:"
      echo "  adminUsername: \"admin\""
      if [[ "$FFMPEG" == yes ]]; then
        echo "integrations:"
        echo "  media:"
        echo "    ffmpegPath: \"/usr/bin\""
      fi
    } > "$FB_CONFIG"
    chown "$FB_USER:$FB_USER" "$FB_CONFIG"
    chmod 600 "$FB_CONFIG"
    info "Wrote $FB_CONFIG"
  fi

  # ---- systemd
  step "Setting up the service"
  cat > "$FB_UNIT" <<EOF
$MARKER
[Unit]
Description=FileBrowser Quantum
After=network-online.target local-fs.target
Wants=network-online.target
RequiresMountsFor=$DATA_DIR

[Service]
User=$FB_USER
Group=$FB_USER
WorkingDirectory=$FB_HOME
ExecStart=$FB_BIN -c $FB_CONFIG
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable filebrowser >/dev/null 2>&1
  local STARTED_AT; STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
  systemctl restart filebrowser
  if ! wait_for_fb; then
    journalctl -u filebrowser -n 25 --no-pager | sed 's/^/    /'
    die "FileBrowser didn't start (log above). Config: $FB_CONFIG"
  fi
  info "FileBrowser running on 127.0.0.1:$PORT"

  # ---- nginx
  step "Configuring nginx"
  local CUR_SITE other
  CUR_SITE="$(ngx_site)"
  if https_on "$CUR_SITE"; then
    # Never replace a working HTTPS site, whatever it's called
    info "nginx site $(basename "$CUR_SITE") already has HTTPS; leaving it alone"
  else
    write_nginx_site "$PORT"
    ln -sf "$NGX_SITE" /etc/nginx/sites-enabled/filebrowser
    rm -f /etc/nginx/sites-enabled/default
    # Retire any other plain-HTTP site (e.g. from a manual setup) that proxies to the same FileBrowser
    for other in /etc/nginx/sites-enabled/*; do
      [[ -e "$other" ]] || continue
      if [[ "$(readlink -f "$other")" == "$NGX_SITE" ]]; then continue; fi
      if grep -q "proxy_pass http://127.0.0.1:${PORT}" "$other" 2>/dev/null; then
        rm -f "$other"
        info "Disabled older nginx site $(basename "$other") (it pointed at the same FileBrowser)"
      fi
    done
  fi
  systemctl enable --now nginx >/dev/null 2>&1
  nginx_test_reload || die "nginx config test failed (details above)"
  if curl -fsS --max-time 10 -o /dev/null http://127.0.0.1/ 2>/dev/null || curl -fsSk --max-time 10 -o /dev/null https://127.0.0.1/ 2>/dev/null; then
    info "nginx is serving FileBrowser"
  else
    warn "nginx didn't answer; check: systemctl status nginx"
  fi

  # ---- done
  local PW=""
  if [[ "$ALREADY" == no ]]; then PW="$(journalctl -u filebrowser --since "$STARTED_AT" --no-pager 2>/dev/null \
        | sed -n 's/.*Generated initial admin password for user "\([^"]*\)".*: \(.*\)$/\1 \2/p' | tail -1)"; fi
  echo
  echo -e "${C_G}======================================================${C_0}"
  echo -e "${C_G} FileBrowser is installed!${C_0}"
  echo -e "${C_G}======================================================${C_0}"
  echo
  if https_on "$(ngx_site)"; then echo "  Open:            https://$(site_domain "$(ngx_site)")/"
  else echo "  Open:            http://${ip}/"; fi
  if [[ -n "$PW" ]]; then
    echo "  Username:        ${PW%% *}"
    echo "  Password:        ${PW#* }   (one-time; you'll be asked to change it)"
  else
    echo "  Login:           use your existing admin account"
  fi
  echo "  Files stored in: $DATA_DIR"
  echo "  Config:          $FB_CONFIG"
  echo
  echo "  Tip: start uploads from the 'Files' view, not from a settings page."
  echo "  Recommended next: fail2ban, swap, and a domain (DuckDNS) + HTTPS."
}

write_nginx_site() {
  local port="$1"
  cat > "$NGX_SITE" <<EOF
$MARKER
server {
    listen 80;
    listen [::]:80;
    server_name _;

    # No upload size limit (FileBrowser uploads in chunks anyway)
    client_max_body_size 0;
    proxy_request_buffering off;
    proxy_buffering off;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
  if [[ ! -s /proc/net/if_inet6 ]]; then
    sed -i '/listen \[::\]:80;/d' "$NGX_SITE"
    info "IPv6 not available; nginx will listen on IPv4 only"
  fi
}

# ==================================================================== check ==
do_check() {
  CHK_BAD=0; CHK_WARN=0
  local VER LATEST DATA PORT URL LISTEN line SITE
  SITE="$(ngx_site)"

  step "FileBrowser"
  if ! fb_installed; then
    c_bad "FileBrowser isn't installed"
  else
    VER="$(fb_version)"
    LATEST="$(latest_stable_tag)"
    if [[ -z "$LATEST" ]]; then c_ok "Version ${VER:-?} (couldn't check for updates)"
    elif [[ "$VER" == "$LATEST" ]]; then c_ok "Version $VER (latest stable)"
    else c_warn "Version $VER; $LATEST is available (use the update option)"; fi

    if systemctl is-active --quiet filebrowser; then c_ok "Service running"
    else c_bad "Service not running (check: journalctl -u filebrowser -n 30)"; fi
    if systemctl is-enabled --quiet filebrowser 2>/dev/null; then c_ok "Starts at boot"; else c_warn "Not enabled at boot (systemctl enable filebrowser)"; fi

    PORT="$(cfg_port)"; LISTEN="$(cfg_value listen)"
    if fb_health; then c_ok "Answering on 127.0.0.1:$PORT"; else c_bad "Not answering on 127.0.0.1:$PORT"; fi
    if [[ "$LISTEN" == "127.0.0.1" || "$LISTEN" == "localhost" ]]; then c_ok "Only reachable through nginx (listen: $LISTEN)"
    else c_warn "Listening on '${LISTEN:-all addresses}': port $PORT may be reachable from the internet, bypassing nginx"; fi
    if [[ "$(stat -c %a "$FB_CONFIG")" == 600 ]]; then c_ok "Config file is private (600)"
    else c_warn "Config file permissions are $(stat -c %a "$FB_CONFIG") (600 recommended): chmod 600 $FB_CONFIG"; fi

    step "nginx"
    if systemctl is-active --quiet nginx; then c_ok "nginx running"; else c_bad "nginx not running"; fi
    if nginx -t >/dev/null 2>&1; then c_ok "nginx config valid"; else c_bad "nginx config has errors (nginx -t)"; fi
    if curl -fsS --max-time 10 -o /dev/null http://127.0.0.1/ 2>/dev/null || curl -fsSk --max-time 10 -o /dev/null https://127.0.0.1/ 2>/dev/null; then
      c_ok "Site answering through nginx"
    else
      c_bad "Site not answering through nginx"
    fi
    c_info "Site file: $SITE"
    if grep -qE 'client_max_body_size[[:space:]]+0;' "$SITE" 2>/dev/null; then c_ok "No nginx upload size limit"
    else c_warn "nginx may limit upload size (client_max_body_size)"; fi

    step "Where things live"
    DATA="$(cfg_source_path)"
    path_info "$FB_HOME"
    local APP_DISK="$PI_DISK"
    c_info "App data   $FB_HOME  →  $PI_DEV ($PI_FS, $PI_FREE free, $(rota_text "$PI_ROTA"))"
    path_info "$DATA"
    c_info "Files      $DATA  →  $PI_DEV ($PI_FS, $PI_FREE free, $(rota_text "$PI_ROTA"))"
    echo
    if [[ ! -d "$DATA" ]]; then c_bad "Files folder $DATA doesn't exist"; fi
    if [[ "$DATA" == /mnt/* || "$DATA" == /media/* ]] && [[ "$PI_MNT" == "/" ]]; then
      c_bad "Files folder is on the system disk; the data drive may not be mounted!"
    elif [[ "$PI_DISK" != "$APP_DISK" ]]; then
      c_ok "Files on a separate drive; app database on the system disk"
    else
      c_info "Files and app data are on the same disk"
    fi
    case "$PI_FS" in vfat|exfat|ntfs|ntfs3|fuseblk) c_bad "Files drive is $PI_FS (no Linux permissions); ext4 recommended" ;; esac
    if [[ -d "$DATA" ]]; then
      if sudo -u "$FB_USER" test -w "$DATA"; then c_ok "$FB_USER can write to $DATA"; else c_bad "$FB_USER can't write to $DATA (chown $FB_USER:$FB_USER $DATA)"; fi
    fi
    if [[ "$PI_MNT" != "/" ]]; then
      line="$(awk -v m="$PI_MNT" '$1 !~ /^#/ && $2 == m' /etc/fstab)"
      if [[ -z "$line" ]]; then c_bad "$PI_MNT isn't in /etc/fstab, so it won't mount after a reboot"
      elif [[ "$line" != *nofail* ]]; then c_warn "$PI_MNT is in fstab without 'nofail'; boot may hang if the drive is missing"
      else c_ok "$PI_MNT mounts automatically at boot"; fi
      if grep -q "RequiresMountsFor=" "$FB_UNIT" 2>/dev/null; then c_ok "Service waits for the drive to be mounted"; fi
    fi
    local ROOT_FREE_KB; ROOT_FREE_KB="$(df -Pk / | awk 'NR==2 {print $4}')"
    if (( ROOT_FREE_KB < 1048576 )); then c_bad "System disk almost full ($(df -Ph / | awk 'NR==2 {print $4}') free)"
    else c_ok "System disk: $(df -Ph / | awk 'NR==2 {print $4}') free"; fi

    URL="$(cfg_value externalUrl)"
    step "Share links"
    c_info "Share links use: ${URL:-(not set)}"
    if [[ "$URL" == https://* ]]; then c_ok "Share links use HTTPS"
    elif https_on "$SITE"; then c_warn "HTTPS is set up but share links still use http (fix it with the HTTPS option)"
    fi
  fi

  step "Memory"
  local RAM SWAP_MB
  RAM="$(ram_mb)"; SWAP_MB="$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)"
  c_info "RAM: ${RAM} MB total, $(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo) MB available"
  if systemctl is-active --quiet filebrowser 2>/dev/null; then
    c_info "FileBrowser using $(ps -o rss= -p "$(systemctl show -p MainPID --value filebrowser)" 2>/dev/null | awk '{print int($1/1024)}' || echo '?') MB"
  fi
  if (( SWAP_MB == 0 )); then
    if (( RAM < 2048 )); then c_warn "No swap (recommended under 2 GB RAM)"; else c_info "No swap"; fi
  else
    c_ok "Swap: ${SWAP_MB} MB (swappiness $(cat /proc/sys/vm/swappiness))"
  fi

  step "Security"
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    local JAILS; JAILS="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')"
    c_ok "fail2ban running (jails: ${JAILS:-none})"
    if [[ "$JAILS" != *filebrowser* ]]; then c_warn "fail2ban has no FileBrowser jail"; fi
  else
    c_warn "fail2ban isn't running (brute-force protection)"
  fi
  if https_on "$SITE"; then
    c_ok "HTTPS enabled ($(site_domain "$SITE"))"
    if cert_info "$SITE"; then
      if (( CERT_DAYS < 0 )); then c_bad "Certificate EXPIRED on $CERT_END"
      elif (( CERT_DAYS < 15 )); then c_warn "Certificate expires in $CERT_DAYS days ($CERT_END) and hasn't renewed yet"
      else c_ok "Certificate valid until $CERT_END ($CERT_DAYS days)"; fi
    fi
    if grep -q "Strict-Transport-Security" "$SITE"; then c_ok "HSTS header set"; else c_info "HSTS not enabled"; fi
    if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then c_ok "Certificate auto-renewal enabled"
    else c_warn "certbot.timer not enabled; the certificate won't renew automatically"; fi
  else
    c_warn "Plain HTTP; passwords travel unencrypted (set up a domain + HTTPS)"
  fi

  if duck_configured; then
    step "DuckDNS"
    duck_check_lines
  elif duck_external; then
    step "DuckDNS"
    duck_external_lines
  fi

  echo
  if (( CHK_BAD == 0 && CHK_WARN == 0 )); then echo -e "  ${C_G}All good!${C_0}"
  else echo -e "  ${C_B}Summary:${C_0} ${C_R}${CHK_BAD} problem(s)${C_0}, ${C_Y}${CHK_WARN} warning(s)${C_0}"; fi
}

# =================================================================== update ==
do_update() {
  step "Update FileBrowser"
  require_fb
  local CUR LATEST TAG tmpbin BACKUP_BIN BACKUP_DB
  CUR="$(fb_version)"
  LATEST="$(latest_stable_tag)"
  info "Installed:      ${CUR:-unknown}"
  info "Latest stable:  ${LATEST:-could not check}"
  echo
  if [[ -n "$ENV_FB_VERSION" ]]; then
    TAG="$ENV_FB_VERSION"
  else
    [[ -n "$LATEST" ]] || die "Couldn't find the latest release (GitHub unreachable?). You can set FB_VERSION=vX.Y.Z-stable."
    TAG="$LATEST"
  fi
  if [[ "$CUR" == "$TAG" ]]; then
    info "Already on $TAG."
    if [[ "$(ask_yn "Reinstall it anyway?" no)" != yes ]]; then return 0; fi
  fi
  if [[ "${CUR%%.*}" != "${TAG%%.*}" ]]; then
    warn "This is a major version change (${CUR%%.*} → ${TAG%%.*}). Config options may have changed;"
    warn "read the release notes first: https://github.com/${REPO}/releases/tag/${TAG}"
    if [[ "$(ask_yn "Continue with the update?" no)" != yes ]]; then info "Cancelled."; return 0; fi
  elif [[ "$(ask_yn "Update to $TAG?" yes)" != yes ]]; then
    info "Cancelled."; return 0
  fi

  tmpbin="$(mktemp)"
  download_fb "$TAG" "$tmpbin"

  step "Backing up"
  BACKUP_BIN="${FB_BIN}.bak"
  BACKUP_DB="${FB_DB}.pre-${TAG}.bak"
  cp -p "$FB_BIN" "$BACKUP_BIN"
  info "Old binary → $BACKUP_BIN"
  systemctl stop filebrowser
  if [[ -f "$FB_DB" ]]; then
    cp -p "$FB_DB" "$BACKUP_DB"
    info "Database   → $BACKUP_DB"
  fi

  step "Installing $TAG"
  install -m 755 "$tmpbin" "$FB_BIN"
  rm -f "$tmpbin"
  systemctl start filebrowser || true
  if wait_for_fb; then
    info "FileBrowser $(fb_version) is running ✓"
    info "If everything looks fine, you can delete the backups later:"
    info "  rm $BACKUP_BIN $BACKUP_DB"
  else
    warn "The new version didn't start; rolling back."
    journalctl -u filebrowser -n 20 --no-pager | sed 's/^/    /'
    systemctl stop filebrowser || true
    cp -p "$BACKUP_BIN" "$FB_BIN"
    if [[ -f "$BACKUP_DB" ]]; then cp -p "$BACKUP_DB" "$FB_DB"; fi
    systemctl start filebrowser || true
    if wait_for_fb; then die "Update failed; rolled back to $CUR, which is running again."
    else die "Update failed and the rollback didn't start either. See: journalctl -u filebrowser -n 50"; fi
  fi
}

# ================================================================= password ==
do_password() {
  step "Reset a password / create a user"
  require_fb
  [[ "$ASSUME_YES" == no ]] || die "This option needs a terminal to type the password."
  local U P1 P2 ADMINFLAG="" ADMIN_NAME OUT
  ADMIN_NAME="$(cfg_value adminUsername)"; ADMIN_NAME="${ADMIN_NAME:-admin}"
  echo
  info "Sets a new password for an existing user, or creates the user if it doesn't exist."
  info "(FileBrowser is stopped for a few seconds while this runs.)"
  echo
  while true; do
    U="$(ask "Username" "$ADMIN_NAME")"
    if [[ "$U" =~ ^[A-Za-z0-9._@-]+$ ]]; then break; fi
    warn "Use letters, numbers and . _ @ - only."
  done
  while true; do
    P1="$(ask_secret "New password (hidden)")"
    if (( ${#P1} < 8 )); then warn "Use at least 8 characters."; continue; fi
    P2="$(ask_secret "Type it again")"
    if [[ "$P1" == "$P2" ]]; then break; fi
    warn "They didn't match; try again."
  done
  if [[ "$U" != "$ADMIN_NAME" ]] && [[ "$(ask_yn "Give '$U' admin rights?" no)" == yes ]]; then ADMINFLAG="--admin"; fi

  systemctl stop filebrowser
  if OUT="$(cd "$FB_HOME" && printf '%s' "$P1" | sudo -u "$FB_USER" "$FB_BIN" -c "$FB_CONFIG" user set "$U" $ADMINFLAG --password 2>&1)"; then
    systemctl start filebrowser
    wait_for_fb || warn "FileBrowser is slow to come back; check: systemctl status filebrowser"
    info "$(grep -oE 'successfully [a-z]+ user.*' <<<"$OUT" | head -1)"
    info "You can log in as '$U' now."
  else
    systemctl start filebrowser || true
    echo "$OUT" | tail -5 | sed 's/^/    /'
    die "Couldn't set the password (output above)."
  fi
}

# ===================================================================== swap ==
create_swapfile() {
  local size="$1" mb free_mb
  case "$size" in *G) mb=$(( ${size%G} * 1024 )) ;; *M) mb=${size%M} ;; esac
  free_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  if (( free_mb < mb + 1024 )); then
    die "Not enough space on the system disk for a ${size} swap file (${free_mb} MB free, need ${mb} MB + 1 GB spare)."
  fi
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
    info "Turning off the current swap file..."
    swapoff "$SWAPFILE"
  fi
  rm -f "$SWAPFILE"
  info "Creating ${size} swap file at $SWAPFILE..."
  if ! fallocate -l "${mb}M" "$SWAPFILE" 2>/dev/null; then
    dd if=/dev/zero of="$SWAPFILE" bs=1M count="$mb" status=progress
  fi
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null
  swapon "$SWAPFILE"
  if ! grep -q "^${SWAPFILE}[[:space:]]" /etc/fstab; then
    echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
    info "Added to /etc/fstab so it survives reboots"
  fi
}

do_swap() {
  step "Swap file"
  local CUR_FILE=no OTHER SIZE ACT SW
  echo
  if swapon --show --noheadings 2>/dev/null | grep -q .; then swapon --show | sed 's/^/    /'
  else info "No swap is active."; fi
  info "RAM: $(ram_mb) MB, system disk free: $(df -Ph / | awk 'NR==2 {print $4}')"
  echo
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then CUR_FILE=yes; fi
  OTHER="$(swapon --show=NAME --noheadings 2>/dev/null | grep -vx "$SWAPFILE" || true)"

  if [[ "$CUR_FILE" == yes ]]; then
    while true; do
      ACT="$(ask "Swap file exists. (k)eep, (r)esize, or (d)elete?" "k")"
      case "${ACT,,}" in k|keep|r|resize|d|delete) break ;; esac
      warn "Answer k, r or d."
    done
    case "${ACT,,}" in
      k|keep) info "Keeping the current swap file." ;;
      d|delete)
        if [[ "$(ask_yn "Really remove the swap file?" no)" == yes ]]; then
          swapoff "$SWAPFILE"; rm -f "$SWAPFILE"
          sed -i "\|^${SWAPFILE}[[:space:]]|d" /etc/fstab
          info "Swap file removed."
        fi
        return 0 ;;
      r|resize)
        while true; do
          SIZE="$(ask "New size (e.g. 1G, 2G, 512M)" "$(rec_swap)")"; SIZE="${SIZE^^}"
          if [[ "$SIZE" =~ ^[0-9]+[MG]$ ]]; then break; fi
          warn "Use a number followed by M or G."
        done
        create_swapfile "$SIZE" ;;
    esac
  else
    if [[ -n "$OTHER" ]]; then
      info "You already have swap ($OTHER)."
      if [[ "$(ask_yn "Add a swap file as well?" no)" != yes ]]; then return 0; fi
    fi
    while true; do
      SIZE="$(ask "Swap file size (e.g. 1G, 2G, 512M)" "$(rec_swap)")"; SIZE="${SIZE^^}"
      if [[ "$SIZE" =~ ^[0-9]+[MG]$ ]]; then break; fi
      warn "Use a number followed by M or G."
      if [[ "$ASSUME_YES" == yes ]]; then die "Invalid swap size"; fi
    done
    create_swapfile "$SIZE"
  fi

  echo
  info "Swappiness controls how eagerly Linux uses swap (0-100)."
  info "10 = only when RAM is nearly full, which suits a safety-net swap file."
  while true; do
    SW="$(ask "Swappiness" "$(awk '{ if ($1==60) print 10; else print $1 }' /proc/sys/vm/swappiness)")"
    if [[ "$SW" =~ ^[0-9]+$ ]] && (( SW <= 100 )); then break; fi
    warn "Enter a number from 0 to 100."
    if [[ "$ASSUME_YES" == yes ]]; then die "Invalid swappiness"; fi
  done
  echo "vm.swappiness=${SW}" > "$SWAPPINESS_CONF"
  sysctl -q -w "vm.swappiness=${SW}"
  echo
  free -h | sed 's/^/    /'
}

# ================================================================= fail2ban ==
do_fail2ban() {
  step "fail2ban (brute-force protection)"
  local MYIP IGNORE tok HAS_SSH=no HAS_FB=no up=no okay CNT
  if [[ -x /usr/sbin/sshd ]]; then HAS_SSH=yes; fi
  if fb_installed; then HAS_FB=yes; fi
  if [[ "$HAS_SSH" == no && "$HAS_FB" == no ]]; then die "Nothing to protect: no SSH server and no FileBrowser found."; fi

  echo
  info "Bans an IP after repeated failed logins:"
  if [[ "$HAS_SSH" == yes ]]; then info "  SSH:          5 failures in 10 min → banned 1 hour"; fi
  if [[ "$HAS_FB" == yes ]];  then info "  FileBrowser:  5 failures in 1 hour  → banned 24 hours"; fi
  echo
  info "IPs on the ignore list can never be banned. Add your home IP so a"
  info "few typos can't lock you out. (Leave blank if your home IP changes.)"
  MYIP="${SSH_CLIENT%% *}"
  if [[ -z "$MYIP" ]]; then MYIP="$(who -m 2>/dev/null | grep -oE '\(([0-9]{1,3}\.){3}[0-9]{1,3}\)' | tr -d '()' || true)"; fi
  if [[ -n "$MYIP" ]]; then info "You're connected from: $MYIP"; fi

  while true; do
    IGNORE="$(ask "IPs to never ban (space-separated)" "$MYIP")"
    okay=yes
    for tok in $IGNORE; do
      if [[ ! "$tok" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]; then okay=no; warn "'$tok' doesn't look like an IP address."; fi
    done
    if [[ "$okay" == yes ]]; then break; fi
    if [[ "$ASSUME_YES" == yes ]]; then die "Invalid ignore IPs"; fi
  done

  step "Installing fail2ban"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -q fail2ban nftables python3-systemd >/dev/null
  info "Installed"

  if [[ "$HAS_FB" == yes ]]; then
    # Watches nginx's log (it has the real visitor IP). Failed logins are 401, rate-limited are 429.
    # A correct first-time login returns 403 (password change required), so 403 isn't counted.
    cat > "$F2B_FILTER" <<'EOF'
# Managed by filebrowser-setup.sh
[Definition]
failregex = ^<HOST> \S+ \S+ .*"POST /api/auth/(?:login|otp/verify)[^"]*" (?:401|429)
ignoreregex =
EOF
    touch /var/log/nginx/access.log
    info "FileBrowser filter written (watching /var/log/nginx/access.log)"
  fi

  if [[ -f "$F2B_JAIL" ]] && ! grep -qF "$MARKER" "$F2B_JAIL"; then
    cp "$F2B_JAIL" "${F2B_JAIL}.bak.$(date +%Y%m%d%H%M%S)"
    info "Backed up your existing jail.local"
  fi
  {
    echo "$MARKER"
    echo "[DEFAULT]"
    echo "ignoreip = 127.0.0.1/8 ::1${IGNORE:+ $IGNORE}"
    echo "banaction = nftables-multiport"
    echo "banaction_allports = nftables-allports"
    echo "bantime = 1h"
    echo "findtime = 10m"
    echo "maxretry = 5"
    if [[ "$HAS_SSH" == yes ]]; then
      echo; echo "[sshd]"; echo "enabled = true"; echo "backend = systemd"
    fi
    if [[ "$HAS_FB" == yes ]]; then
      echo; echo "[filebrowser]"; echo "enabled = true"; echo "port = 80,443"
      echo "filter = filebrowser"; echo "logpath = /var/log/nginx/access.log"
      echo "maxretry = 5"; echo "findtime = 1h"; echo "bantime = 24h"
    fi
  } > "$F2B_JAIL"
  info "Jails written to $F2B_JAIL"

  step "Starting fail2ban"
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban || true
  for _ in $(seq 1 15); do
    if fail2ban-client ping >/dev/null 2>&1; then up=yes; break; fi
    sleep 1
  done
  if [[ "$up" != yes ]]; then
    journalctl -u fail2ban -n 20 --no-pager | sed 's/^/    /'
    die "fail2ban didn't start (log above)."
  fi
  fail2ban-client status | sed 's/^/    /'
  if [[ "$HAS_FB" == yes ]]; then
    CNT="$(fail2ban-regex /var/log/nginx/access.log "$F2B_FILTER" 2>/dev/null | awk '/^Failregex:/ {print $2; exit}' || true)"
    echo
    info "Failed FileBrowser logins found in the log so far: ${CNT:-0}"
  fi
  echo
  info "See bans:   fail2ban-client status filebrowser   /   fail2ban-client status sshd"
  info "Unban:      fail2ban-client unban 1.2.3.4"
  info "(FileBrowser also has its own lockout: 8 wrong tries per username locks it for 15 min.)"
}

# ================================================================== duckdns ==
duck_check_lines() {
  local last res age ip d st=0
  c_info "Names: $(duck_domains | sed 's/,/.duckdns.org, /g').duckdns.org"
  if systemctl is-active --quiet duckdns-update.timer 2>/dev/null; then c_ok "Updater runs every 5 minutes"
  else c_bad "Updater isn't scheduled (fix: systemctl enable --now duckdns-update.timer)"; fi
  last="$(duck_last)"
  if [[ -z "$last" ]]; then
    c_warn "No update has run yet"
  else
    res="$(awk '{print $3}' <<<"$last")"; age="$(duck_last_age_min)"; ip="$(duck_last_ip)"
    if [[ "$res" == "OK" ]]; then
      if (( age > 15 )); then c_warn "Last successful update was $age minutes ago (IP $ip)"
      else c_ok "Last update OK, $age min ago (IP $ip)"; fi
    else
      c_bad "Last update failed: $(cut -d' ' -f3- <<<"$last")"
    fi
  fi
  d="$(duck_first_fqdn)"
  dns_check "$d" || st=$?
  case "$st" in
    0) c_ok "$d resolves to this server ($DNS_IPS)" ;;
    2) c_warn "$d doesn't resolve yet" ;;
    *) c_warn "$d resolves to $DNS_IPS (after an IP change, DNS can take a few minutes to catch up)" ;;
  esac
}

write_duck_files() {
  cat > "$DUCK_BIN" <<'EOF'
#!/bin/sh
# Managed by filebrowser-setup.sh: tells DuckDNS this server's current public IP.
. /etc/duckdns.conf
mkdir -p /var/lib/duckdns
# The URL (with the token) goes to curl on stdin so the token never shows up in the process list
r="$(printf 'url = "https://www.duckdns.org/update?domains=%s&token=%s&ip=&verbose=true"\n' \
      "$DUCKDNS_DOMAINS" "$DUCKDNS_TOKEN" | curl -fsS --max-time 30 -K - 2>&1)" || r="ERROR $r"
r="$(printf '%s' "$r" | tr '\n' ' ' | tr -s ' ')"
echo "$(date '+%Y-%m-%d %H:%M:%S') $r" > /var/lib/duckdns/last
echo "DuckDNS: $r"
case "$r" in OK*) exit 0 ;; *) exit 1 ;; esac
EOF
  chmod 755 "$DUCK_BIN"

  cat > "$DUCK_SVC" <<EOF
$MARKER
[Unit]
Description=Update DuckDNS with this server's IP
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$DUCK_BIN
EOF

  cat > "$DUCK_TIMER" <<EOF
$MARKER
[Unit]
Description=Update DuckDNS every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF
}

duck_remove_old_cron() {
  local f
  if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -qE 'duckdns\.org/update|duck[^[:space:]/]*\.sh'; then
    echo
    info "Found an older DuckDNS cron job (probably from duckdns.org's instructions):"
    crontab -l 2>/dev/null | grep -E 'duckdns\.org/update|duck[^[:space:]/]*\.sh' | sed 's/^/      /'
    if [[ "$(ask_yn "Remove it? The new updater replaces it." yes)" == yes ]]; then
      { crontab -l 2>/dev/null | grep -vE 'duckdns\.org/update|duck[^[:space:]/]*\.sh' || true; } | crontab -
      info "Old cron job removed. (Its folder, often ~/duckdns, can be deleted too.)"
    fi
  fi
  for f in /etc/crontab /etc/cron.d/*; do
    if [[ -f "$f" ]] && grep -qE 'duckdns\.org/update|duck[^[:space:]/]*\.sh' "$f" 2>/dev/null; then
      warn "$f also updates DuckDNS; remove that line so they don't both run."
    fi
  done
}

duck_setup() {
  local SUB TOKEN OLD_SUB OLD_TOKEN BACKUP="" st=0 d
  echo
  info "DuckDNS gives you a free name like yourname.duckdns.org and this keeps it"
  info "pointed at this server. Sign in at https://www.duckdns.org, create a"
  info "subdomain there, and copy the token shown at the top of the page."
  echo
  OLD_SUB="$(duck_domains)"
  OLD_TOKEN="$(sed -nE 's/^DUCKDNS_TOKEN="?([^"]*)"?.*/\1/p' "$DUCK_CONF" 2>/dev/null | head -1 || true)"
  if [[ -z "$OLD_SUB" && -z "$OLD_TOKEN" ]] && duck_external; then
    OLD_SUB="$EXT_DOMAINS"; OLD_TOKEN="$EXT_TOKEN"
    if [[ -n "$OLD_TOKEN" ]]; then info "Using the subdomain and token from your existing DuckDNS cron job."; echo; fi
  fi

  while true; do
    SUB="$(ask "Subdomain (e.g. myfiles or myfiles.duckdns.org)" "${OLD_SUB:-${DUCKDNS_DOMAIN:-}}")"
    SUB="${SUB,,}"; SUB="${SUB// /}"; SUB="${SUB//.duckdns.org/}"
    if [[ "$SUB" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]]; then break; fi
    warn "Just the name part, like myfiles (several can be comma-separated)."
    if [[ "$ASSUME_YES" == yes ]]; then die "Set DUCKDNS_DOMAIN=yourname"; fi
  done

  if [[ "$ASSUME_YES" == yes ]]; then
    TOKEN="${DUCKDNS_TOKEN:-$OLD_TOKEN}"
  else
    while true; do
      if [[ -n "$OLD_TOKEN" ]]; then TOKEN="$(ask_secret "Token (hidden; Enter keeps the current one)")"; TOKEN="${TOKEN:-$OLD_TOKEN}"
      else TOKEN="$(ask_secret "Token (hidden)")"; fi
      TOKEN="${TOKEN// /}"; TOKEN="${TOKEN,,}"
      if [[ "$TOKEN" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then break; fi
      warn "That doesn't look like a DuckDNS token (it looks like xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)."
    done
  fi
  [[ "$TOKEN" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || die "Missing or invalid token (set DUCKDNS_TOKEN)"

  step "Saving settings and testing them with DuckDNS"
  apt-get install -y -q curl >/dev/null
  if [[ -f "$DUCK_CONF" ]]; then BACKUP="${DUCK_CONF}.bak"; cp -p "$DUCK_CONF" "$BACKUP"; fi
  ( umask 077; printf '%s\nDUCKDNS_DOMAINS="%s"\nDUCKDNS_TOKEN="%s"\n' "$MARKER" "$SUB" "$TOKEN" > "$DUCK_CONF" )
  write_duck_files
  if ! "$DUCK_BIN" | sed 's/^/    /'; then
    if [[ -n "$BACKUP" ]]; then cp -p "$BACKUP" "$DUCK_CONF"
    else rm -f "$DUCK_CONF" "$DUCK_BIN" "$DUCK_SVC" "$DUCK_TIMER"; rm -rf "$(dirname "$DUCK_STATE")"; fi
    die "DuckDNS rejected the update (KO usually means a wrong token or a subdomain that isn't on your account). Nothing was changed."
  fi
  info "DuckDNS accepted the update ✓"

  systemctl daemon-reload
  systemctl enable --now duckdns-update.timer >/dev/null 2>&1
  if systemctl is-active --quiet duckdns-update.timer; then info "Updater scheduled every 5 minutes"
  else warn "Couldn't start the updater timer; check: systemctl status duckdns-update.timer"; fi

  duck_remove_old_cron

  d="${SUB%%,*}.duckdns.org"
  dns_check "$d" || st=$?
  echo
  case "$st" in
    0) info "$d → $DNS_IPS (this server) ✓" ;;
    2) info "$d doesn't resolve yet; give it a minute." ;;
    *) info "$d currently resolves to $DNS_IPS; it can take a few minutes to update." ;;
  esac
  if fb_installed && ! https_on "$(ngx_site)"; then info "Next: set up HTTPS for $d (the HTTPS option will suggest it)."; fi
}

duck_remove() {
  if [[ "$(ask_yn "Stop updating DuckDNS and remove the updater?" no)" != yes ]]; then info "Cancelled."; return 0; fi
  systemctl disable --now duckdns-update.timer >/dev/null 2>&1 || true
  rm -f "$DUCK_TIMER" "$DUCK_SVC" "$DUCK_BIN" "$DUCK_CONF" "${DUCK_CONF}.bak"
  rm -rf "$(dirname "$DUCK_STATE")"
  systemctl daemon-reload
  info "Removed. Your name still exists at duckdns.org; it just won't follow this server's IP anymore."
}

do_duckdns() {
  step "Dynamic DNS (DuckDNS)"
  local ACT
  if ! duck_configured && duck_external; then
    CHK_BAD=0; CHK_WARN=0
    duck_external_lines
    echo
    info "That works fine as it is. Taking it over switches to this script's updater"
    info "(a systemd timer, with status shown in the menu and health check) using the"
    info "same subdomain and token, and removes the old cron job."
    echo
    if [[ "$(ask_yn "Take it over?" no)" == yes ]]; then duck_setup; fi
    return 0
  fi
  if ! duck_configured; then duck_setup; return 0; fi
  CHK_BAD=0; CHK_WARN=0
  duck_check_lines
  echo
  echo "  What next?"
  echo "    u) Update now"
  echo "    c) Change the subdomain or token"
  echo "    r) Remove the updater"
  ACT="$(ask "Choose (or Enter if you're just checking)" "done")"
  case "${ACT,,}" in
    u) if "$DUCK_BIN" | sed 's/^/    /'; then info "Updated ✓"; else warn "Update failed (see above)."; fi ;;
    c) duck_setup ;;
    r) duck_remove ;;
    *) return 0 ;;
  esac
}

# ==================================================================== https ==
add_hsts() {
  local site="$1"
  if grep -q "Strict-Transport-Security" "$site"; then info "HSTS is already on"; return 0; fi
  cp "$site" "${site}.bak"
  # Goes inside the HTTPS server block, right after its "listen ... 443 ssl" line
  sed -i -E '0,/^([[:space:]]*listen[^;]*443[^;]*ssl[^;]*;.*)$/s//\1\n    add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;/' "$site"
  if grep -q "Strict-Transport-Security" "$site" && nginx_test_reload; then
    info "HSTS turned on"
  else
    cp "${site}.bak" "$site"; systemctl reload nginx || true
    warn "Couldn't add HSTS; restored the previous config. HTTPS itself still works."
  fi
}

set_share_url() {
  local url="$1"
  if ! grep -qE '^[[:space:]]*externalUrl:' "$FB_CONFIG"; then
    warn "No externalUrl line in $FB_CONFIG. Add it under 'http:' as:  externalUrl: \"$url\""
    return 0
  fi
  cp -p "$FB_CONFIG" "${FB_CONFIG}.bak"
  sed -i -E "s|^([[:space:]]*externalUrl:).*|\1 \"${url}\"|" "$FB_CONFIG"
  systemctl restart filebrowser
  if wait_for_fb; then
    info "Share links now use $url (links made earlier keep their old address; recreate any you need)"
  else
    cp -p "${FB_CONFIG}.bak" "$FB_CONFIG"; systemctl restart filebrowser || true
    die "FileBrowser didn't restart; restored the previous config."
  fi
}

https_status() {
  local SITE="$1" DOM URL ACT st=0 CAN_HSTS=no CAN_SHARE=no
  CHK_BAD=0; CHK_WARN=0
  DOM="$(site_domain "$SITE")"
  c_info "nginx site: $SITE"
  c_ok "HTTPS is set up for $DOM"
  if cert_info "$SITE"; then
    if (( CERT_DAYS < 0 )); then c_bad "Certificate EXPIRED on $CERT_END"
    elif (( CERT_DAYS < 15 )); then c_warn "Certificate expires in $CERT_DAYS days ($CERT_END) and hasn't renewed yet"
    else c_ok "Certificate valid until $CERT_END ($CERT_DAYS days left)"; fi
  else
    c_warn "Couldn't read the certificate details"
  fi
  if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then c_ok "Auto-renewal scheduled (renews about 30 days before expiry)"
  else c_warn "certbot.timer isn't enabled, so the certificate won't renew by itself"; fi
  if grep -q 'return 301 https://' "$SITE"; then c_ok "http:// redirects to https://"
  else c_warn "http:// isn't redirected to https://"; fi
  if grep -q "Strict-Transport-Security" "$SITE"; then c_ok "HSTS on"
  else c_info "HSTS off"; CAN_HSTS=yes; fi
  URL="$(cfg_value externalUrl)"
  if [[ "$URL" == "https://$DOM" ]]; then c_ok "Share links use https://$DOM"
  else c_warn "Share links use ${URL:-(not set)} instead of https://$DOM"; CAN_SHARE=yes; fi
  dns_check "$DOM" || st=$?
  case "$st" in
    0) c_ok "$DOM resolves to this server ($DNS_IPS)" ;;
    2) c_bad "$DOM doesn't resolve" ;;
    *) c_warn "$DOM resolves to $DNS_IPS, not this server" ;;
  esac
  if [[ "$DOM" == *.duckdns.org ]] && ! duck_configured; then
    c_info "Tip: the DuckDNS option keeps $DOM pointed at this server if its IP changes"
  fi

  echo
  echo "  What next?"
  echo "    t) Test certificate renewal (dry run)"
  if [[ "$CAN_HSTS" == yes ]]; then echo "    h) Turn on HSTS"; fi
  if [[ "$CAN_SHARE" == yes ]]; then echo "    s) Make share links use https://$DOM"; fi
  echo "    n) Move to a different domain"
  ACT="$(ask "Choose (or Enter if you're just checking)" "done")"
  case "${ACT,,}" in
    t)
      step "Testing certificate renewal"
      if certbot renew --dry-run 2>&1 | tail -4 | sed 's/^/    /'; then :; fi
      if certbot renew --dry-run >/dev/null 2>&1; then info "Renewal works ✓"; else warn "Renewal test failed; see: certbot renew --dry-run"; fi ;;
    h) add_hsts "$SITE" ;;
    s) set_share_url "https://$DOM" ;;
    n) https_setup "$SITE" "$DOM" ;;
    *) return 0 ;;
  esac
}

https_setup() {
  local SITE="$1" OLD="$2" DOM DEF EMAIL HSTS=no st=0
  [[ -f "$SITE" ]] || die "nginx site config not found ($SITE). Run the install first."
  echo
  info "You need a domain (e.g. files.example.com or yourname.duckdns.org) that"
  info "points at this server, and ports 80 + 443 open in any provider firewall."
  echo
  DEF="${DOMAIN:-$(duck_first_fqdn)}"
  if [[ -n "$OLD" && "$DEF" == "$OLD" ]]; then DEF=""; fi
  while true; do
    DOM="$(ask "Domain name" "$DEF")"; DOM="${DOM,,}"
    if [[ -n "$OLD" && "$DOM" == "$OLD" ]]; then warn "That's the current domain."; continue; fi
    if [[ "$DOM" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then break; fi
    warn "Enter a domain like files.example.com (no http://, not an IP address)."
    if [[ "$ASSUME_YES" == yes ]]; then die "Invalid domain: '$DOM'"; fi
  done

  dns_check "$DOM" || st=$?
  case "$st" in
    0) info "$DOM → $DNS_IPS (this server) ✓" ;;
    2)
      warn "$DOM doesn't resolve to any address yet."
      if [[ "$DOM" == *.duckdns.org ]] && ! duck_configured; then warn "Set it up with the DuckDNS option first."; fi
      if [[ "$(ask_yn "Try anyway?" no)" != yes ]]; then info "Cancelled."; return 0; fi ;;
    *)
      warn "$DOM points to $DNS_IPS, but this server's addresses are: $(hostname -I 2>/dev/null)"
      warn "Fine behind NAT/a proxy; otherwise the certificate request will fail."
      if [[ "$(ask_yn "Continue anyway?" no)" != yes ]]; then info "Cancelled."; return 0; fi ;;
  esac

  while true; do
    EMAIL="$(ask "Email for certificate expiry notices (Enter to skip)" "${CERTBOT_EMAIL:-}")"
    if [[ -z "$EMAIL" || ( "$EMAIL" == *@*.* && "$EMAIL" != *" "* ) ]]; then break; fi
    warn "Enter a valid email address, or leave it blank."
    if [[ "$ASSUME_YES" == yes ]]; then die "Invalid email"; fi
  done
  if ! grep -q "Strict-Transport-Security" "$SITE"; then
    echo
    info "HSTS tells browsers to only ever use HTTPS for this domain (for 6 months)."
    info "Recommended, but once on, you can't easily go back to plain HTTP."
    HSTS="$(ask_yn "Enable HSTS?" yes)"
  fi

  step "Pointing nginx at $DOM"
  cp "$SITE" "${SITE}.bak"
  if [[ -n "$OLD" ]]; then
    # Moving domains: rename everywhere except the certificate paths (certbot replaces those)
    sed -i "/ssl_certificate/! s/${OLD//./\\.}/${DOM}/g" "$SITE"
  elif ! grep -qE "server_name[^;]*[[:space:]]${DOM//./\\.}[[:space:];]" "$SITE"; then
    sed -i -E "0,/server_name ([^;]*);/s//server_name ${DOM};/" "$SITE"
  fi
  if ! nginx_test_reload; then
    cp "${SITE}.bak" "$SITE"; systemctl reload nginx || true
    die "nginx rejected the change; restored the previous config."
  fi

  step "Requesting the certificate"
  apt-get install -y -q python3-certbot-nginx openssl >/dev/null
  local -a EMAIL_ARGS=(--register-unsafely-without-email)
  if [[ -n "$EMAIL" ]]; then EMAIL_ARGS=(-m "$EMAIL"); fi
  if ! certbot --nginx -d "$DOM" --non-interactive --agree-tos "${EMAIL_ARGS[@]}" --redirect; then
    cp "${SITE}.bak" "$SITE"; systemctl reload nginx || true
    die "Certbot couldn't get a certificate, so nginx was put back as it was. Usual causes: DNS not pointing here yet, or ports 80/443 blocked in your provider's firewall."
  fi
  if [[ "$HSTS" == yes ]]; then add_hsts "$SITE"; fi

  step "Updating share links"
  set_share_url "https://${DOM}"

  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  if systemctl is-enabled --quiet certbot.timer 2>/dev/null; then info "Certificate auto-renewal enabled"; fi
  if curl -fsS --max-time 10 -o /dev/null --resolve "${DOM}:443:127.0.0.1" "https://${DOM}/"; then
    info "https://${DOM} is answering with a valid certificate ✓"
  else
    warn "Couldn't confirm https://${DOM} from the server itself; try it in your browser."
  fi
  if [[ -n "$OLD" ]]; then info "The old certificate isn't used anymore; remove it with: certbot delete --cert-name $OLD"; fi
  echo
  info "Done: https://${DOM}/"
}

do_https() {
  local SITE
  step "HTTPS with Let's Encrypt"
  require_fb
  SITE="$(ngx_site)"
  if https_on "$SITE"; then https_status "$SITE"; else https_setup "$SITE" ""; fi
}

# ===================================================================== menu ==
run_action() {
  local a="$1"
  trap - ERR
  set +e
  (
    set -e
    trap 'on_error $LINENO "$BASH_COMMAND"' ERR
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "----- ${a}: $(date) -----" >>"$LOG_FILE"
    "do_${a}"
  )
  RUN_RC=$?
  sleep 0.2
  set -e
  trap 'on_error $LINENO "$BASH_COMMAND"' ERR
}

menu() {
  local choice s_fb s_swap s_f2b s_https s_duck site
  while true; do
    if fb_installed; then
      if systemctl is-active --quiet filebrowser 2>/dev/null; then s_fb="${C_G}running${C_0} · $(fb_version) · $(cfg_value externalUrl)"
      else s_fb="${C_R}installed but not running${C_0}"; fi
    else
      s_fb="${C_Y}not installed${C_0}"
    fi
    if swapon --show --noheadings 2>/dev/null | grep -q .; then s_swap="${C_G}[$(free -h | awk '/^Swap:/ {print $2}')]${C_0}"; else s_swap="${C_D}[none]${C_0}"; fi
    if systemctl is-active --quiet fail2ban 2>/dev/null; then s_f2b="${C_G}[on]${C_0}"; else s_f2b="${C_D}[off]${C_0}"; fi
    if duck_configured; then
      if [[ "$(duck_last | awk '{print $3}')" == "OK" ]]; then s_duck="${C_G}[on · $(duck_first_fqdn)]${C_0}"
      else s_duck="${C_Y}[on · last update failed]${C_0}"; fi
    elif duck_external; then
      if [[ -n "$EXT_DOMAINS" ]]; then s_duck="${C_G}[on · ${EXT_DOMAINS%%,*}.duckdns.org · via cron]${C_0}"
      else s_duck="${C_G}[on · via cron]${C_0}"; fi
    else
      s_duck="${C_D}[off]${C_0}"
    fi
    site="$(ngx_site)"
    if https_on "$site"; then
      if cert_info "$site"; then
        if (( CERT_DAYS < 15 )); then s_https="${C_Y}[on · $(site_domain "$site") · ${CERT_DAYS} days left]${C_0}"
        else s_https="${C_G}[on · $(site_domain "$site") · ${CERT_DAYS} days left]${C_0}"; fi
      else
        s_https="${C_G}[on · $(site_domain "$site")]${C_0}"
      fi
    else
      s_https="${C_D}[off]${C_0}"
    fi
    echo
    echo -e "${C_B}  ==================================================${C_0}"
    echo -e "${C_B}   FileBrowser Quantum setup${C_0}"
    echo -e "${C_B}  ==================================================${C_0}"
    echo -e "   FileBrowser: ${s_fb}"
    echo -e "   RAM: $(ram_mb) MB · system disk free: $(df -Ph / | awk 'NR==2 {print $4}')"
    echo
    echo    "   1) Install FileBrowser"
    echo    "   2) Check setup"
    echo    "   3) Update FileBrowser"
    echo    "   4) Reset a password / add a user"
    echo -e "   5) Swap file                          ${s_swap}"
    echo -e "   6) fail2ban (block brute-force)       ${s_f2b}"
    echo -e "   7) DuckDNS (set up or check)          ${s_duck}"
    echo -e "   8) HTTPS (set up or check)            ${s_https}"
    echo    "   q) Quit"
    echo
    printf '  Choose an option: ' >/dev/tty
    IFS= read -r choice </dev/tty || exit 0
    case "${choice,,}" in
      1) run_action install ;;
      2) run_action check ;;
      3) run_action update ;;
      4) run_action password ;;
      5) run_action swap ;;
      6) run_action fail2ban ;;
      7) run_action duckdns ;;
      8) run_action https ;;
      q|quit|exit) echo; exit 0 ;;
      "") continue ;;
      *) warn "Pick 1-8 or q."; continue ;;
    esac
    if (( RUN_RC != 0 )); then warn "That option didn't finish (see the error above)."; fi
    pause
  done
}

# ===================================================================== main ==
[[ $EUID -eq 0 ]] || die "Run this as root: sudo bash $0"
mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
RUN_RC=0

if [[ -n "$ACTION" ]]; then
  if [[ "$ASSUME_YES" == no && ! -r /dev/tty ]]; then die "No terminal for questions. Add -y to use defaults."; fi
  run_action "$ACTION"
  exit "$RUN_RC"
fi
if [[ "$ASSUME_YES" == yes ]]; then die "-y needs an action, e.g.: $0 install -y"; fi
[[ -r /dev/tty ]] || die "The menu needs a terminal. Run an action directly instead (see --help)."
menu
