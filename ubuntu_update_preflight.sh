#!/usr/bin/env bash
# Ubuntu Update Preflight Checker (read-only)
#
# Mini-README:
# - Purpose: Run a preflight risk assessment before apt upgrade/dist-upgrade without changing packages.
# - Scope: Ubuntu systems (apt/dpkg).
# - Outputs: Human-readable report + optional JSON + optional email notification.
# - Exit codes: 0=GREEN, 1=YELLOW, 2=RED, 3=ERROR.
#
# Example (cron):
#   15 5 * * * /usr/local/bin/ubuntu_update_preflight.sh --mode local --to ops@example.com --json on --json-path /var/log/update-preflight.json
#
# Example (Ansible):
#   - name: Run preflight
#     command: >-
#       /usr/local/bin/ubuntu_update_preflight.sh --mode off --json on
#       --json-path /tmp/preflight.json --report-path /tmp/preflight.txt
#     register: preflight
#     changed_when: false
#     failed_when: preflight.rc == 3

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_NAME="$(basename "$0")"
VERSION="1.0.0"

MODE="off"              # off|local|smtp
JSON_MODE="off"         # on|off
REFRESH="off"           # on|off
VERBOSE="off"
DRY_RUN_MAIL="off"
TOP_N=20
TIMEOUT=20
THRESHOLD_VAR_GB=2
THRESHOLD_ROOT_GB=3
THRESHOLD_REMOVALS_RED=0

REPORT_PATH="/tmp/ubuntu-update-preflight-report.txt"
JSON_PATH="/tmp/ubuntu-update-preflight-report.json"
TO_ADDR=""
FROM_ADDR=""
SUBJECT_PREFIX="[Preflight]"

SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
SMTP_PASS_FILE="${SMTP_PASS_FILE:-}"
SMTP_TLS="${SMTP_TLS:-on}" # on|off
SMTP_FROM="${SMTP_FROM:-}"

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
TIMESTAMP_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

STATUS="GREEN"
GO_NOGO="Go"
EXIT_CODE=0

declare -a RED_REASONS=()
declare -a YELLOW_REASONS=()
declare -a INFO_NOTES=()
declare -a RECOMMENDATIONS=()

declare -a UPDATES=()
declare -a UPDATES_SEC=()
declare -a UPDATES_UNKNOWN_SEC=()
declare -a HELD_PACKAGES=()
declare -a MAJOR_JUMPS=()
declare -a CONFFILE_RISKS=()
declare -a REMOVAL_LINES=()
declare -a KEPT_BACK_LINES=()

APT_UPGRADE_SIM=""
APT_DIST_SIM=""

log() {
  if [[ "$VERBOSE" == "on" ]]; then
    printf '[%s] %s\n' "$(date +'%F %T')" "$*" >&2
  fi
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  EXIT_CODE=3
  STATUS="ERROR"
  GO_NOGO="No-Go"
  exit 3
}

on_err() {
  local code=$?
  if [[ $code -ne 0 ]]; then
    printf '[ERROR] Unexpected failure at line %s (exit=%s).\n' "$1" "$code" >&2
  fi
}
trap 'on_err $LINENO' ERR

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [options]
  --to EMAIL
  --from EMAIL
  --subject-prefix PREFIX
  --mode off|local|smtp
  --json on|off
  --report-path PATH
  --json-path PATH
  --top-n N
  --threshold-var-gb N
  --threshold-root-gb N
  --threshold-removals-red N
  --timeout SEC
  --refresh on|off
  --dry-run-mail on|off
  --verbose
  -h|--help
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to) TO_ADDR="${2:-}"; shift 2 ;;
      --from) FROM_ADDR="${2:-}"; shift 2 ;;
      --subject-prefix) SUBJECT_PREFIX="${2:-}"; shift 2 ;;
      --mode) MODE="${2:-}"; shift 2 ;;
      --json) JSON_MODE="${2:-}"; shift 2 ;;
      --report-path) REPORT_PATH="${2:-}"; shift 2 ;;
      --json-path) JSON_PATH="${2:-}"; shift 2 ;;
      --top-n) TOP_N="${2:-}"; shift 2 ;;
      --threshold-var-gb) THRESHOLD_VAR_GB="${2:-}"; shift 2 ;;
      --threshold-root-gb) THRESHOLD_ROOT_GB="${2:-}"; shift 2 ;;
      --threshold-removals-red) THRESHOLD_REMOVALS_RED="${2:-}"; shift 2 ;;
      --timeout) TIMEOUT="${2:-}"; shift 2 ;;
      --refresh) REFRESH="${2:-}"; shift 2 ;;
      --dry-run-mail) DRY_RUN_MAIL="${2:-}"; shift 2 ;;
      --verbose) VERBOSE="on"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  [[ "$MODE" =~ ^(off|local|smtp)$ ]] || die "--mode must be off|local|smtp"
  [[ "$JSON_MODE" =~ ^(on|off)$ ]] || die "--json must be on|off"
  [[ "$REFRESH" =~ ^(on|off)$ ]] || die "--refresh must be on|off"
  [[ "$DRY_RUN_MAIL" =~ ^(on|off)$ ]] || die "--dry-run-mail must be on|off"
  [[ "$TOP_N" =~ ^[0-9]+$ ]] || die "--top-n must be numeric"
  [[ "$THRESHOLD_VAR_GB" =~ ^[0-9]+$ ]] || die "--threshold-var-gb must be numeric"
  [[ "$THRESHOLD_ROOT_GB" =~ ^[0-9]+$ ]] || die "--threshold-root-gb must be numeric"
  [[ "$THRESHOLD_REMOVALS_RED" =~ ^[0-9]+$ ]] || die "--threshold-removals-red must be numeric"
  [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be numeric"

  if [[ -z "$FROM_ADDR" ]]; then
    FROM_ADDR="$SMTP_FROM"
  fi
}

json_escape() {
  local s="${1:-}"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

write_atomic() {
  local path="$1"
  local content="$2"
  umask 077
  local tmp
  tmp="$(mktemp "${path}.XXXXXX")"
  printf '%s' "$content" >"$tmp"
  mv "$tmp" "$path"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

get_os_data() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
  fi
  OS_PRETTY="${PRETTY_NAME:-unknown}"
  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-unknown}"
  OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
  KERNEL="$(uname -r)"
  UPTIME_HUMAN="$(uptime -p 2>/dev/null || true)"
}

check_ubuntu() {
  if [[ "$OS_ID" != "ubuntu" ]]; then
    RED_REASONS+=("Unsupported OS ID '$OS_ID' (expected ubuntu)")
  fi
}

get_mount_avail_gb() {
  local path="$1"
  df -BG "$path" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4+0}'
}

resource_checks() {
  ROOT_AVAIL_GB="$(get_mount_avail_gb / || echo 0)"
  VAR_AVAIL_GB="$(get_mount_avail_gb /var || echo "$ROOT_AVAIL_GB")"
  BOOT_AVAIL_GB="$(get_mount_avail_gb /boot || echo -1)"
  RAM_LINE="$(free -m 2>/dev/null | awk '/^Mem:/ {print $2"MB total, "$7"MB available"}' || true)"
  SWAP_LINE="$(free -m 2>/dev/null | awk '/^Swap:/ {print $2"MB total, "$4"MB free"}' || true)"

  if (( ROOT_AVAIL_GB < THRESHOLD_ROOT_GB )); then
    RED_REASONS+=("Low free space on / (${ROOT_AVAIL_GB}GB < ${THRESHOLD_ROOT_GB}GB)")
  elif (( ROOT_AVAIL_GB < THRESHOLD_ROOT_GB + 2 )); then
    YELLOW_REASONS+=("Moderate free space on / (${ROOT_AVAIL_GB}GB)")
  fi

  if (( VAR_AVAIL_GB < THRESHOLD_VAR_GB )); then
    RED_REASONS+=("Low free space on /var (${VAR_AVAIL_GB}GB < ${THRESHOLD_VAR_GB}GB)")
  elif (( VAR_AVAIL_GB < THRESHOLD_VAR_GB + 2 )); then
    YELLOW_REASONS+=("Moderate free space on /var (${VAR_AVAIL_GB}GB)")
  fi
}

network_soft_check() {
  if command_exists getent; then
    if ! timeout "$TIMEOUT" getent hosts archive.ubuntu.com >/dev/null 2>&1; then
      INFO_NOTES+=("DNS check failed or timed out for archive.ubuntu.com")
    fi
  fi
}

refresh_metadata() {
  if [[ "$REFRESH" == "on" ]]; then
    log "Running apt-get update (metadata refresh only)"
    if ! timeout "$TIMEOUT" apt-get update -qq >/tmp/preflight-apt-update.log 2>&1; then
      YELLOW_REASONS+=("apt-get update failed/timed out; update list may be stale")
      INFO_NOTES+=("apt-get update log: /tmp/preflight-apt-update.log")
    fi
  else
    INFO_NOTES+=("Apt metadata refresh skipped (--refresh off); update list may be stale")
  fi
}

collect_upgradable() {
  local line pkg inst cand
  if apt list --upgradable >/tmp/preflight-upgradable.txt 2>/dev/null; then
    while IFS= read -r line; do
      [[ "$line" == "Listing..."* ]] && continue
      [[ -z "$line" ]] && continue
      pkg="${line%%/*}"
      cand="$(awk -F'/' '{print $2}' <<<"$line" | awk '{print $1}')"
      inst="$(sed -n 's/.*upgradable from: \([^]]*\).*/\1/p' <<<"$line")"
      UPDATES+=("${pkg}|${inst:-unknown}|${cand:-unknown}")
    done </tmp/preflight-upgradable.txt
  else
    INFO_NOTES+=("apt list --upgradable unavailable; using apt-get -s upgrade fallback")
    while IFS= read -r line; do
      [[ "$line" =~ ^Inst[[:space:]]+ ]] || continue
      pkg="$(awk '{print $2}' <<<"$line")"
      cand="$(sed -n 's/.*(\([^ ]*\).*/\1/p' <<<"$line" | head -n1)"
      UPDATES+=("${pkg}|unknown|${cand:-unknown}")
    done < <(apt-get -s upgrade)
  fi
}

security_classification() {
  local entry pkg policy
  for entry in "${UPDATES[@]}"; do
    pkg="${entry%%|*}"
    policy="$(apt-cache policy "$pkg" 2>/dev/null || true)"
    if grep -Eqi 'security|ubuntu-security' <<<"$policy"; then
      UPDATES_SEC+=("$entry")
    else
      UPDATES_UNKNOWN_SEC+=("$entry")
    fi
  done
}

collect_holds_pins() {
  mapfile -t HELD_PACKAGES < <(apt-mark showhold 2>/dev/null || true)
  if (( ${#HELD_PACKAGES[@]} > 0 )); then
    YELLOW_REASONS+=("Held packages detected (${#HELD_PACKAGES[@]})")
  fi

  if compgen -G "/etc/apt/preferences" >/dev/null || compgen -G "/etc/apt/preferences.d/*" >/dev/null; then
    YELLOW_REASONS+=("APT pinning preferences detected")
  fi
}

version_major() {
  local v="$1"
  v="${v#*:}"
  v="${v%%[-+~]*}"
  v="${v%%.*}"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "$v"
  else
    echo "-1"
  fi
}

collect_conffile_and_major_risks() {
  local entry pkg inst cand conf inst_major cand_major
  for entry in "${UPDATES[@]}"; do
    IFS='|' read -r pkg inst cand <<<"$entry"

    conf="$(dpkg-query -W -f='${Conffiles}\n' "$pkg" 2>/dev/null || true)"
    if grep -q '/etc/' <<<"$conf"; then
      CONFFILE_RISKS+=("$pkg")
    fi

    if [[ "$inst" == "unknown" || "$cand" == "unknown" ]]; then
      continue
    fi
    inst_major="$(version_major "$inst")"
    cand_major="$(version_major "$cand")"
    if (( inst_major >= 0 && cand_major > inst_major )); then
      MAJOR_JUMPS+=("$pkg:$inst->$cand")
    fi
  done

  if (( ${#CONFFILE_RISKS[@]} > 0 )); then
    YELLOW_REASONS+=("Potential conffile impact for ${#CONFFILE_RISKS[@]} packages")
  fi
  if (( ${#MAJOR_JUMPS[@]} > 0 )); then
    YELLOW_REASONS+=("Major version jumps detected (${#MAJOR_JUMPS[@]})")
  fi
}

simulate_apt() {
  APT_UPGRADE_SIM="$(apt-get -s upgrade 2>&1 || true)"
  APT_DIST_SIM="$(apt-get -s dist-upgrade 2>&1 || true)"

  mapfile -t REMOVAL_LINES < <(grep -E '^Remv ' <<<"$APT_DIST_SIM" || true)
  mapfile -t KEPT_BACK_LINES < <(grep -E 'kept back' <<<"$APT_UPGRADE_SIM" || true)

  if (( ${#REMOVAL_LINES[@]} > THRESHOLD_REMOVALS_RED )); then
    RED_REASONS+=("Simulated dist-upgrade removals: ${#REMOVAL_LINES[@]}")
  elif (( ${#REMOVAL_LINES[@]} > 0 )); then
    YELLOW_REASONS+=("Simulated removals present (${#REMOVAL_LINES[@]})")
  fi

  if grep -Eqi 'broken packages|unmet dependencies|depends:' <<<"$APT_UPGRADE_SIM$APT_DIST_SIM"; then
    RED_REASONS+=("Dependency/broken package indicators found in simulation")
  fi

  if (( ${#KEPT_BACK_LINES[@]} > 0 )); then
    YELLOW_REASONS+=("Kept-back packages detected")
  fi
}

check_restart_risk() {
  local restart_likely="off"
  if command_exists needrestart; then
    local nr
    nr="$(needrestart -b 2>/dev/null || true)"
    if grep -Eq 'NEEDRESTART-(KSTA|SVC):\s*[1-9]' <<<"$nr"; then
      restart_likely="on"
      YELLOW_REASONS+=("needrestart indicates restart/reload activity")
    fi
  else
    INFO_NOTES+=("needrestart not installed; using heuristics")
  fi

  local entry pkg
  for entry in "${UPDATES[@]}"; do
    pkg="${entry%%|*}"
    if [[ "$pkg" =~ ^(linux-image|linux-headers|linux-generic|linux-modules) ]]; then
      YELLOW_REASONS+=("Kernel update detected ($pkg)")
      restart_likely="on"
      break
    fi
  done

  for entry in "${UPDATES[@]}"; do
    pkg="${entry%%|*}"
    if [[ "$pkg" =~ ^(libc6|systemd|openssl|libssl|dbus|initramfs-tools)$ ]]; then
      YELLOW_REASONS+=("Core runtime/library update detected ($pkg), restart likely")
      restart_likely="on"
    fi
  done

  if [[ "$restart_likely" == "on" ]]; then
    INFO_NOTES+=("Service restart/reboot likely after real upgrade")
  fi
}

analyze_repos() {
  local files=()
  [[ -f /etc/apt/sources.list ]] && files+=(/etc/apt/sources.list)
  while IFS= read -r f; do files+=("$f"); done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f -name '*.list' 2>/dev/null || true)

  local line suite repo_host detected_suite mismatch=0
  for f in "${files[@]}"; do
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      [[ "$line" =~ ^deb[[:space:]] ]] || continue

      if grep -Eqi 'proposed|devel' <<<"$line"; then
        RED_REASONS+=("Risky repo suite detected in $f: $line")
      fi
      if grep -Eqi 'backports' <<<"$line"; then
        YELLOW_REASONS+=("Backports repo enabled in $f")
      fi

      local uri_field
      uri_field="$(awk '{if ($2 ~ /^\[/) print $3; else print $2}' <<<"$line")"
      repo_host="$(sed -E 's#https?://##; s#/.*##' <<<"$uri_field")"
      if [[ -n "$repo_host" ]] && ! grep -Eq '(archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|ubuntu\.com)$' <<<"$repo_host"; then
        YELLOW_REASONS+=("Third-party repo detected: $repo_host")
      fi

      suite="$(awk '{print $3}' <<<"$line")"
      detected_suite="${suite%%-*}"
      if [[ "$OS_CODENAME" != "unknown" && -n "$detected_suite" && "$detected_suite" != "stable" && "$detected_suite" != "$OS_CODENAME" ]]; then
        mismatch=1
      fi
    done <"$f"
  done
  if (( mismatch == 1 )); then
    RED_REASONS+=("APT suite/codename mismatch vs running OS codename ($OS_CODENAME)")
  fi

  INFO_NOTES+=("Phased updates explicit detection: not fully available via standard CLI output")
}

dedupe_array() {
  awk '!seen[$0]++'
}

finalize_status() {
  mapfile -t RED_REASONS < <(printf '%s\n' "${RED_REASONS[@]:-}" | sed '/^$/d' | dedupe_array)
  mapfile -t YELLOW_REASONS < <(printf '%s\n' "${YELLOW_REASONS[@]:-}" | sed '/^$/d' | dedupe_array)
  mapfile -t INFO_NOTES < <(printf '%s\n' "${INFO_NOTES[@]:-}" | sed '/^$/d' | dedupe_array)

  if (( ${#RED_REASONS[@]} > 0 )); then
    STATUS="RED"
    GO_NOGO="No-Go"
    EXIT_CODE=2
  elif (( ${#YELLOW_REASONS[@]} > 0 )); then
    STATUS="YELLOW"
    GO_NOGO="Conditional Go"
    EXIT_CODE=1
  else
    STATUS="GREEN"
    GO_NOGO="Go"
    EXIT_CODE=0
  fi

  if [[ "$STATUS" == "GREEN" ]]; then
    RECOMMENDATIONS=(
      "Proceed with normal maintenance window."
      "Run apt-get upgrade in controlled mode and review logs."
    )
  elif [[ "$STATUS" == "YELLOW" ]]; then
    RECOMMENDATIONS=(
      "Proceed only with review of listed risk indicators."
      "Plan service restarts/reboot if kernel/core libs are updated."
      "Validate third-party repositories and held packages before upgrade."
    )
  else
    RECOMMENDATIONS=(
      "Do NOT proceed with upgrade until RED findings are resolved."
      "Review dependency/removal simulation and repository configuration."
      "Re-run preflight after remediation."
    )
  fi
}

build_text_report() {
  local report=""
  local i entry pkg inst cand
  report+="# Ubuntu Update Preflight Report\n"
  report+="Generated: ${TIMESTAMP_UTC}\n"
  report+="Host: ${HOSTNAME_FQDN}\n"
  report+="Status: ${STATUS}\n"
  report+="Recommendation: ${GO_NOGO}\n\n"

  report+="## Key Findings\n"
  if (( ${#RED_REASONS[@]} > 0 )); then
    for i in "${RED_REASONS[@]}"; do report+="- [RED] $i\n"; done
  fi
  if (( ${#YELLOW_REASONS[@]} > 0 )); then
    for i in "${YELLOW_REASONS[@]}"; do report+="- [YELLOW] $i\n"; done
  fi
  if (( ${#RED_REASONS[@]} == 0 && ${#YELLOW_REASONS[@]} == 0 )); then
    report+="- No critical warnings detected.\n"
  fi
  report+="\n"

  report+="## Updates\n"
  report+="- Total upgradable: ${#UPDATES[@]}\n"
  report+="- Security-indicated: ${#UPDATES_SEC[@]}\n"
  report+="- Non-security/unknown: ${#UPDATES_UNKNOWN_SEC[@]}\n"
  report+="- Top ${TOP_N}:\n"
  local count=0
  for entry in "${UPDATES[@]}"; do
    ((count++)) || true
    (( count > TOP_N )) && break
    IFS='|' read -r pkg inst cand <<<"$entry"
    report+="  - ${pkg}: ${inst} -> ${cand}\n"
  done
  report+="\n"

  report+="## Risk Indicators\n"
  report+="- Conffile-related packages: ${#CONFFILE_RISKS[@]}\n"
  report+="- Major version jumps: ${#MAJOR_JUMPS[@]}\n"
  report+="- Held packages: ${#HELD_PACKAGES[@]}\n"
  report+="- Simulated removals: ${#REMOVAL_LINES[@]}\n"
  report+="- Kept back lines: ${#KEPT_BACK_LINES[@]}\n\n"

  report+="## System\n"
  report+="- OS: ${OS_PRETTY} (${OS_CODENAME})\n"
  report+="- Kernel: ${KERNEL}\n"
  report+="- Uptime: ${UPTIME_HUMAN}\n"
  report+="- Free /: ${ROOT_AVAIL_GB}GB\n"
  report+="- Free /var: ${VAR_AVAIL_GB}GB\n"
  if (( BOOT_AVAIL_GB >= 0 )); then
    report+="- Free /boot: ${BOOT_AVAIL_GB}GB\n"
  fi
  report+="- RAM: ${RAM_LINE:-unknown}\n"
  report+="- Swap: ${SWAP_LINE:-unknown}\n\n"

  report+="## Recommendations\n"
  for i in "${RECOMMENDATIONS[@]}"; do report+="- $i\n"; done

  if (( ${#INFO_NOTES[@]} > 0 )); then
    report+="\n## Notes\n"
    for i in "${INFO_NOTES[@]}"; do report+="- $i\n"; done
  fi

  TEXT_REPORT="$(printf '%b' "$report")"
}

json_array_strings() {
  local arr=("$@")
  local out=""
  local i
  for i in "${!arr[@]}"; do
    out+="\"$(json_escape "${arr[$i]}")\""
    if (( i < ${#arr[@]} - 1 )); then out+=","; fi
  done
  printf '[%s]' "$out"
}

build_json_report() {
  local updates_json=""
  local i entry pkg inst cand
  for i in "${!UPDATES[@]}"; do
    entry="${UPDATES[$i]}"
    IFS='|' read -r pkg inst cand <<<"$entry"
    updates_json+="{\"package\":\"$(json_escape "$pkg")\",\"installed\":\"$(json_escape "$inst")\",\"candidate\":\"$(json_escape "$cand")\"}"
    if (( i < ${#UPDATES[@]} - 1 )); then updates_json+=","; fi
  done

  JSON_REPORT=$(cat <<JSON
{
  "status": "$(json_escape "$STATUS")",
  "go_nogo": "$(json_escape "$GO_NOGO")",
  "host": "$(json_escape "$HOSTNAME_FQDN")",
  "timestamp": "$(json_escape "$TIMESTAMP_UTC")",
  "os": {
    "pretty": "$(json_escape "$OS_PRETTY")",
    "id": "$(json_escape "$OS_ID")",
    "version_id": "$(json_escape "$OS_VERSION_ID")",
    "codename": "$(json_escape "$OS_CODENAME")",
    "kernel": "$(json_escape "$KERNEL")"
  },
  "counts": {
    "upgradable": ${#UPDATES[@]},
    "security": ${#UPDATES_SEC[@]},
    "unknown_security": ${#UPDATES_UNKNOWN_SEC[@]},
    "held": ${#HELD_PACKAGES[@]},
    "conffile_risk": ${#CONFFILE_RISKS[@]},
    "major_jumps": ${#MAJOR_JUMPS[@]},
    "simulated_removals": ${#REMOVAL_LINES[@]}
  },
  "checks": {
    "root_avail_gb": ${ROOT_AVAIL_GB},
    "var_avail_gb": ${VAR_AVAIL_GB},
    "boot_avail_gb": ${BOOT_AVAIL_GB}
  },
  "updates": [${updates_json}],
  "risks": {
    "red": $(json_array_strings "${RED_REASONS[@]}"),
    "yellow": $(json_array_strings "${YELLOW_REASONS[@]}"),
    "info": $(json_array_strings "${INFO_NOTES[@]}")
  },
  "recommendations": $(json_array_strings "${RECOMMENDATIONS[@]}")
}
JSON
)
}

send_mail_local() {
  local subject="$1"
  local body="$2"

  if [[ "$DRY_RUN_MAIL" == "on" ]]; then
    INFO_NOTES+=("Dry-run mail enabled; local mail not sent")
    return 0
  fi

  if command_exists sendmail; then
    {
      printf 'From: %s\n' "${FROM_ADDR:-preflight@$HOSTNAME_FQDN}"
      printf 'To: %s\n' "$TO_ADDR"
      printf 'Subject: %s\n' "$subject"
      printf 'Content-Type: text/plain; charset=UTF-8\n'
      printf '\n%s\n' "$body"
    } | sendmail -t
  elif command_exists mail; then
    printf '%s\n' "$body" | mail -s "$subject" -r "${FROM_ADDR:-preflight@$HOSTNAME_FQDN}" "$TO_ADDR"
  else
    die "mode=local but neither sendmail nor mail is available"
  fi
}

send_mail_smtp() {
  local subject="$1"
  local body="$2"

  [[ -n "$SMTP_HOST" ]] || die "mode=smtp requires SMTP_HOST"
  [[ -n "$TO_ADDR" ]] || die "mode=smtp requires --to"

  if [[ -z "$FROM_ADDR" ]]; then
    FROM_ADDR="${SMTP_FROM:-preflight@$HOSTNAME_FQDN}"
  fi

  if [[ -z "$SMTP_PASS" && -n "$SMTP_PASS_FILE" && -f "$SMTP_PASS_FILE" ]]; then
    SMTP_PASS="$(<"$SMTP_PASS_FILE")"
  fi

  if [[ "$DRY_RUN_MAIL" == "on" ]]; then
    INFO_NOTES+=("Dry-run mail enabled; SMTP message not sent")
    return 0
  fi

  local user_b64 pass_b64 auth_block
  if [[ -n "$SMTP_USER" ]]; then
    [[ -n "$SMTP_PASS" ]] || die "SMTP_USER set but SMTP_PASS/SMTP_PASS_FILE missing"
    user_b64="$(printf '%s' "$SMTP_USER" | base64 | tr -d '\n')"
    pass_b64="$(printf '%s' "$SMTP_PASS" | base64 | tr -d '\n')"
    auth_block="AUTH LOGIN\n${user_b64}\n${pass_b64}\n"
  else
    auth_block=""
  fi

  local msg
  msg=$(cat <<EOFMSG
EHLO $HOSTNAME_FQDN
${auth_block}MAIL FROM:<$FROM_ADDR>
RCPT TO:<$TO_ADDR>
DATA
From: $FROM_ADDR
To: $TO_ADDR
Subject: $subject
Content-Type: text/plain; charset=UTF-8

$body
.
QUIT
EOFMSG
)

  if [[ "$SMTP_TLS" == "on" ]]; then
    command_exists openssl || die "SMTP TLS requested but openssl is not available"
    printf '%b' "$msg" | timeout "$TIMEOUT" openssl s_client -quiet -starttls smtp -crlf -connect "${SMTP_HOST}:${SMTP_PORT}" >/tmp/preflight-smtp.log 2>&1 || die "SMTP TLS send failed"
  else
    if command_exists nc; then
      printf '%b' "$msg" | timeout "$TIMEOUT" nc "$SMTP_HOST" "$SMTP_PORT" >/tmp/preflight-smtp.log 2>&1 || die "SMTP plaintext send failed"
    else
      die "SMTP plaintext requires nc"
    fi
  fi
}

maybe_send_mail() {
  local subject="${SUBJECT_PREFIX} ${HOSTNAME_FQDN} ${STATUS} $(date +%F)"

  case "$MODE" in
    off)
      INFO_NOTES+=("Email sending disabled (mode=off)")
      ;;
    local)
      [[ -n "$TO_ADDR" ]] || die "mode=local requires --to"
      send_mail_local "$subject" "$TEXT_REPORT"
      ;;
    smtp)
      send_mail_smtp "$subject" "$TEXT_REPORT"
      ;;
  esac
}

main() {
  parse_args "$@"
  get_os_data
  check_ubuntu
  resource_checks
  network_soft_check
  refresh_metadata
  collect_upgradable
  security_classification
  collect_holds_pins
  collect_conffile_and_major_risks
  simulate_apt
  check_restart_risk
  analyze_repos
  finalize_status
  build_text_report

  write_atomic "$REPORT_PATH" "$TEXT_REPORT"
  if [[ "$JSON_MODE" == "on" ]]; then
    build_json_report
    write_atomic "$JSON_PATH" "$JSON_REPORT"
  fi

  maybe_send_mail

  printf '%s\n' "$TEXT_REPORT"
  exit "$EXIT_CODE"
}

main "$@"
