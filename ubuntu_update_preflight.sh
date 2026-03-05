#!/usr/bin/env bash
# Ubuntu Update Preflight Checker (read-only)
#
# Mini-README:
# - Purpose: Run a preflight risk assessment before apt upgrade/dist-upgrade without changing packages.
# - Scope: Ubuntu systems (apt/dpkg).
# - Outputs: Human-readable report + optional JSON + optional email notification.
# - Safety: Read-only checks only (no apt install/upgrade actions are executed).
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
VERSION="1.1.1"

MODE="off"              # off|local|smtp
JSON_MODE="off"         # on|off
REFRESH="off"           # on|off
VERBOSE="off"
DRY_RUN_MAIL="off"
TOP_N=20
TIMEOUT=20
THRESHOLD_VAR_GB=2
THRESHOLD_ROOT_GB=3
THRESHOLD_REMOVALS_RED=5 # 0 means any removal = RED

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
IN_DIE=0

TMP_FILES=()
cleanup_tmp_files() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup_tmp_files EXIT

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

log_duration() {
  local label="$1" start="$2" end
  end="$(date +%s)"
  log "$label took $(( end - start ))s"
}

die() {
  trap - ERR
  IN_DIE=1
  printf '[ERROR] %s\n' "$*" >&2
  EXIT_CODE=3
  STATUS="ERROR"
  GO_NOGO="No-Go"
  exit 3
}

on_err() {
  local code=$?
  if [[ "$IN_DIE" -eq 1 ]]; then
    return
  fi
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

  if (( THRESHOLD_REMOVALS_RED == 0 )); then
    INFO_NOTES+=("threshold-removals-red=0 means any simulated removal triggers RED")
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

json_escape() {
  local s="${1-}"
  if command_exists python3; then
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1])[1:-1])' "$s"
    return
  fi
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=$(tr -d '\000-\010\013\014\016-\037' <<<"$s")
  printf '%s' "$s"
}

write_atomic() {
  local path="$1" content="$2" tmp
  tmp="$(mktemp "${path}.XXXXXX")"
  chmod 600 "$tmp"
  printf '%s' "$content" >"$tmp"
  mv "$tmp" "$path"
}

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
  [[ "$OS_ID" == "ubuntu" ]] || RED_REASONS+=("Unsupported OS ID '$OS_ID' (expected ubuntu)")
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
  if command_exists getent && ! timeout "$TIMEOUT" getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    INFO_NOTES+=("DNS check failed or timed out for archive.ubuntu.com")
  fi
}

refresh_metadata() {
  local t
  if [[ "$REFRESH" == "on" ]]; then
    t="$(date +%s)"
    if ! timeout "$TIMEOUT" apt-get update -qq >/tmp/preflight-apt-update.log 2>&1; then
      YELLOW_REASONS+=("apt-get update failed/timed out; update list may be stale")
      INFO_NOTES+=("apt-get update log: /tmp/preflight-apt-update.log")
    fi
    log_duration "apt-get update" "$t"
  else
    INFO_NOTES+=("Apt metadata refresh skipped (--refresh off); update list may be stale")
  fi
}

collect_upgradable() {
  local line pkg inst cand
  if apt list --upgradable >/tmp/preflight-upgradable.txt 2>/dev/null; then
    while IFS= read -r line; do
      [[ "$line" == "Listing..."* || -z "$line" ]] && continue
      pkg="${line%%/*}"
      cand="$(awk '{print $2}' <<<"${line#*/}")"
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
  local entry pkg policy_blob section curr_pkg has_sec
  (( ${#UPDATES[@]} > 0 )) || return 0

  local -a pkg_list=()
  for entry in "${UPDATES[@]}"; do pkg_list+=("${entry%%|*}"); done
  policy_blob="$(apt-cache policy "${pkg_list[@]}" 2>/dev/null || true)"

  for entry in "${UPDATES[@]}"; do
    pkg="${entry%%|*}"
    section="$(awk -v p="$pkg" '
      $1==p":" {f=1; next}
      f==1 && /^[^[:space:]]/ {exit}
      f==1 {print}
    ' <<<"$policy_blob")"
    curr_pkg="$pkg"
    has_sec=0
    if grep -Eqi 'security|ubuntu-security' <<<"$section"; then
      has_sec=1
    fi
    if (( has_sec == 1 )); then
      UPDATES_SEC+=("$entry")
    else
      UPDATES_UNKNOWN_SEC+=("$entry")
    fi
  done
}

collect_holds_pins() {
  mapfile -t HELD_PACKAGES < <(apt-mark showhold 2>/dev/null || true)
  (( ${#HELD_PACKAGES[@]} > 0 )) && YELLOW_REASONS+=("Held packages detected (${#HELD_PACKAGES[@]})")
  if compgen -G "/etc/apt/preferences" >/dev/null || compgen -G "/etc/apt/preferences.d/*" >/dev/null; then
    YELLOW_REASONS+=("APT pinning preferences detected")
  fi
}

version_major() {
  local v="$1"
  v="${v#*:}"; v="${v%%[-+~]*}"; v="${v%%.*}"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "-1"
}

collect_conffile_and_major_risks() {
  local entry pkg inst cand conf inst_major cand_major
  for entry in "${UPDATES[@]}"; do
    IFS='|' read -r pkg inst cand <<<"$entry"
    conf="$(dpkg-query -W -f='${Conffiles}\n' "$pkg" 2>/dev/null || true)"
    grep -q '/etc/' <<<"$conf" && CONFFILE_RISKS+=("$pkg")
    [[ "$inst" == "unknown" || "$cand" == "unknown" ]] && continue
    inst_major="$(version_major "$inst")"
    cand_major="$(version_major "$cand")"
    (( inst_major >= 0 && cand_major > inst_major )) && MAJOR_JUMPS+=("$pkg:$inst->$cand")
  done

  (( ${#CONFFILE_RISKS[@]} > 0 )) && YELLOW_REASONS+=("Potential conffile impact for ${#CONFFILE_RISKS[@]} packages")
  (( ${#MAJOR_JUMPS[@]} > 0 )) && YELLOW_REASONS+=("Major version jumps detected (${#MAJOR_JUMPS[@]})")
}

simulate_apt() {
  local t
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    INFO_NOTES+=("Running apt simulations unprivileged; results may be limited on some hosts")
  fi

  t="$(date +%s)"; APT_UPGRADE_SIM="$(apt-get -s upgrade 2>&1 || true)"; log_duration "apt-get -s upgrade" "$t"
  t="$(date +%s)"; APT_DIST_SIM="$(apt-get -s dist-upgrade 2>&1 || true)"; log_duration "apt-get -s dist-upgrade" "$t"

  mapfile -t REMOVAL_LINES < <(grep -E '^Remv ' <<<"$APT_DIST_SIM" || true)
  mapfile -t KEPT_BACK_LINES < <(grep -E 'kept back' <<<"$APT_UPGRADE_SIM" || true)

  if (( ${#REMOVAL_LINES[@]} > THRESHOLD_REMOVALS_RED )); then
    RED_REASONS+=("Simulated dist-upgrade removals: ${#REMOVAL_LINES[@]}")
  elif (( ${#REMOVAL_LINES[@]} > 0 )); then
    YELLOW_REASONS+=("Simulated removals present (${#REMOVAL_LINES[@]})")
  fi

  grep -Eqi 'broken packages|unmet dependencies|depends:' <<<"$APT_UPGRADE_SIM$APT_DIST_SIM" && RED_REASONS+=("Dependency/broken package indicators found in simulation")
  (( ${#KEPT_BACK_LINES[@]} > 0 )) && YELLOW_REASONS+=("Kept-back packages detected")
}

check_restart_risk() {
  local restart_likely="off" nr=""
  if command_exists needrestart; then
    if needrestart -h 2>&1 | grep -q -- '-b'; then
      nr="$(needrestart -b 2>/dev/null || true)"
    else
      INFO_NOTES+=("needrestart without -b support detected; skipped direct parsing")
    fi
    if [[ -n "$nr" ]] && grep -Eq 'NEEDRESTART-(KSTA|SVC):\s*[1-9]' <<<"$nr"; then
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

  [[ "$restart_likely" == "on" ]] && INFO_NOTES+=("Service restart/reboot likely after real upgrade")
}

analyze_repos() {
  local files=()
  [[ -f /etc/apt/sources.list ]] && files+=(/etc/apt/sources.list)
  while IFS= read -r f; do files+=("$f"); done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f -name '*.list' 2>/dev/null || true)

  local line suite repo_host detected_suite mismatch=0 uri_field
  for f in "${files[@]}"; do
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# || "$line" =~ ^[[:space:]]*$ || ! "$line" =~ ^deb[[:space:]] ]] && continue

      grep -Eqi 'proposed|devel' <<<"$line" && RED_REASONS+=("Risky repo suite detected in $f: $line")
      grep -Eqi 'backports' <<<"$line" && YELLOW_REASONS+=("Backports repo enabled in $f")

      uri_field="$(awk '{if ($2 ~ /^\[/) print $3; else print $2}' <<<"$line")"
      repo_host="$(sed -E 's#https?://##; s#/.*##' <<<"$uri_field")"
      if [[ -n "$repo_host" ]] && ! grep -Eq '(archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|ubuntu\.com|esm\.ubuntu\.com|launchpad\.net|launchpadcontent\.net)$' <<<"$repo_host"; then
        YELLOW_REASONS+=("Third-party repo detected: $repo_host")
      fi

      suite="$(awk '{if ($2 ~ /^\[/) print $4; else print $3}' <<<"$line")"
      detected_suite="${suite%%-*}"
      if [[ "$OS_CODENAME" != "unknown" && -n "$detected_suite" && "$detected_suite" != "stable" && "$detected_suite" != "$OS_CODENAME" ]]; then
        mismatch=1
      fi
    done <"$f"
  done
  (( mismatch == 1 )) && RED_REASONS+=("APT suite/codename mismatch vs running OS codename ($OS_CODENAME)")
  INFO_NOTES+=("Phased updates explicit detection: not fully available via standard CLI output")
}

dedupe_array() { awk '!seen[$0]++'; }

finalize_status() {
  mapfile -t RED_REASONS < <(printf '%s\n' "${RED_REASONS[@]:-}" | sed '/^$/d' | dedupe_array)
  mapfile -t YELLOW_REASONS < <(printf '%s\n' "${YELLOW_REASONS[@]:-}" | sed '/^$/d' | dedupe_array)
  mapfile -t INFO_NOTES < <(printf '%s\n' "${INFO_NOTES[@]:-}" | sed '/^$/d' | dedupe_array)

  if (( ${#RED_REASONS[@]} > 0 )); then
    STATUS="RED"; GO_NOGO="No-Go"; EXIT_CODE=2
  elif (( ${#YELLOW_REASONS[@]} > 0 )); then
    STATUS="YELLOW"; GO_NOGO="Conditional Go"; EXIT_CODE=1
  else
    STATUS="GREEN"; GO_NOGO="Go"; EXIT_CODE=0
  fi

  if [[ "$STATUS" == "GREEN" ]]; then
    RECOMMENDATIONS=("Proceed with normal maintenance window." "Run apt-get upgrade in controlled mode and review logs.")
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
  local report="" i entry pkg inst cand count=0
  report+="# Ubuntu Update Preflight Report\n"
  report+="Generated: ${TIMESTAMP_UTC}\nHost: ${HOSTNAME_FQDN}\nStatus: ${STATUS}\nRecommendation: ${GO_NOGO}\n\n"
  report+="## Key Findings\n"
  for i in "${RED_REASONS[@]:-}"; do [[ -n "$i" ]] && report+="- [RED] $i\n"; done
  for i in "${YELLOW_REASONS[@]:-}"; do [[ -n "$i" ]] && report+="- [YELLOW] $i\n"; done
  (( ${#RED_REASONS[@]} == 0 && ${#YELLOW_REASONS[@]} == 0 )) && report+="- No critical warnings detected.\n"

  report+="\n## Updates\n- Total upgradable: ${#UPDATES[@]}\n- Security-indicated: ${#UPDATES_SEC[@]}\n- Non-security/unknown: ${#UPDATES_UNKNOWN_SEC[@]}\n- Top ${TOP_N}:\n"
  for entry in "${UPDATES[@]}"; do
    ((count++)) || true; (( count > TOP_N )) && break
    IFS='|' read -r pkg inst cand <<<"$entry"
    report+="  - ${pkg}: ${inst} -> ${cand}\n"
  done

  report+="\n## Risk Indicators\n"
  report+="- Conffile-related packages: ${#CONFFILE_RISKS[@]}\n- Major version jumps: ${#MAJOR_JUMPS[@]}\n"
  report+="- Held packages: ${#HELD_PACKAGES[@]}\n- Simulated removals: ${#REMOVAL_LINES[@]}\n- Kept back lines: ${#KEPT_BACK_LINES[@]}\n"

  report+="\n## System\n- OS: ${OS_PRETTY} (${OS_CODENAME})\n- Kernel: ${KERNEL}\n- Uptime: ${UPTIME_HUMAN}\n"
  report+="- Free /: ${ROOT_AVAIL_GB}GB\n- Free /var: ${VAR_AVAIL_GB}GB\n"
  (( BOOT_AVAIL_GB >= 0 )) && report+="- Free /boot: ${BOOT_AVAIL_GB}GB\n"
  report+="- RAM: ${RAM_LINE:-unknown}\n- Swap: ${SWAP_LINE:-unknown}\n"

  report+="\n## Recommendations\n"
  for i in "${RECOMMENDATIONS[@]:-}"; do [[ -n "$i" ]] && report+="- $i\n"; done

  if (( ${#INFO_NOTES[@]} > 0 )); then
    report+="\n## Notes\n"
    for i in "${INFO_NOTES[@]:-}"; do [[ -n "$i" ]] && report+="- $i\n"; done
  fi

  TEXT_REPORT="$(printf '%b' "$report")"
}

json_array_strings() {
  local arr=("$@") out="" i
  if (( ${#arr[@]} == 0 )) || [[ -z "${arr[0]:-}" ]]; then
    printf '[]'
    return
  fi
  for i in "${!arr[@]}"; do
    out+="\"$(json_escape "${arr[$i]}")\""
    (( i < ${#arr[@]} - 1 )) && out+=","
  done
  printf '[%s]' "$out"
}

build_json_report() {
  local updates_json="" i entry pkg inst cand
  for i in "${!UPDATES[@]}"; do
    entry="${UPDATES[$i]}"
    IFS='|' read -r pkg inst cand <<<"$entry"
    updates_json+="{\"package\":\"$(json_escape "$pkg")\",\"installed\":\"$(json_escape "$inst")\",\"candidate\":\"$(json_escape "$cand")\"}"
    (( i < ${#UPDATES[@]} - 1 )) && updates_json+=","
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
    "red": $(json_array_strings "${RED_REASONS[@]:-}"),
    "yellow": $(json_array_strings "${YELLOW_REASONS[@]:-}"),
    "info": $(json_array_strings "${INFO_NOTES[@]:-}")
  },
  "recommendations": $(json_array_strings "${RECOMMENDATIONS[@]:-}")
}
JSON
)
}

send_mail_local() {
  local subject="$1" body="$2"
  if [[ "$DRY_RUN_MAIL" == "on" ]]; then
    INFO_NOTES+=("Dry-run mail enabled; local mail not sent")
    return 0
  fi
  if command_exists sendmail; then
    {
      printf 'From: %s\n' "${FROM_ADDR:-preflight@$HOSTNAME_FQDN}"
      printf 'To: %s\n' "$TO_ADDR"
      printf 'Subject: %s\n' "$subject"
      printf 'Content-Type: text/plain; charset=UTF-8\n\n%s\n' "$body"
    } | sendmail -t
  elif command_exists mail; then
    printf '%s\n' "$body" | mail -s "$subject" -r "${FROM_ADDR:-preflight@$HOSTNAME_FQDN}" "$TO_ADDR"
  else
    die "mode=local but neither sendmail nor mail is available"
  fi
}

smtp_send_transcript() {
  local transcript="$1"
  if [[ "$SMTP_TLS" == "on" ]]; then
    command_exists openssl || die "SMTP TLS requested but openssl is not available"
    timeout "$TIMEOUT" openssl s_client -quiet -starttls smtp -crlf -connect "${SMTP_HOST}:${SMTP_PORT}" <"$transcript" >/tmp/preflight-smtp.log 2>&1 || return 1
  else
    command_exists nc || die "SMTP plaintext requires nc"
    timeout "$TIMEOUT" nc "$SMTP_HOST" "$SMTP_PORT" <"$transcript" >/tmp/preflight-smtp.log 2>&1 || return 1
  fi
}

send_mail_smtp() {
  local subject="$1" body="$2"
  [[ -n "$SMTP_HOST" ]] || die "mode=smtp requires SMTP_HOST"
  [[ -n "$TO_ADDR" ]] || die "mode=smtp requires --to"
  [[ -n "$FROM_ADDR" ]] || FROM_ADDR="${SMTP_FROM:-preflight@$HOSTNAME_FQDN}"

  if [[ -z "$SMTP_PASS" && -n "$SMTP_PASS_FILE" && -f "$SMTP_PASS_FILE" ]]; then
    SMTP_PASS="$(<"$SMTP_PASS_FILE")"
  fi

  if [[ "$DRY_RUN_MAIL" == "on" ]]; then
    INFO_NOTES+=("Dry-run mail enabled; SMTP message not sent")
    return 0
  fi

  local transcript user_b64 pass_b64
  transcript="$(mktemp /tmp/preflight-smtp-transcript.XXXXXX)"
  chmod 600 "$transcript"
  TMP_FILES+=("$transcript")

  {
    printf 'EHLO %s\n' "$HOSTNAME_FQDN"
    if [[ -n "$SMTP_USER" ]]; then
      [[ -n "$SMTP_PASS" ]] || die "SMTP_USER set but SMTP_PASS/SMTP_PASS_FILE missing"
      user_b64="$(printf '%s' "$SMTP_USER" | base64 | tr -d '\n')"
      pass_b64="$(printf '%s' "$SMTP_PASS" | base64 | tr -d '\n')"
      printf 'AUTH LOGIN\n%s\n%s\n' "$user_b64" "$pass_b64"
    fi
    printf 'MAIL FROM:<%s>\nRCPT TO:<%s>\nDATA\n' "$FROM_ADDR" "$TO_ADDR"
    printf 'From: %s\nTo: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n' "$FROM_ADDR" "$TO_ADDR" "$subject"
    printf '%s\n.\nQUIT\n' "$body"
  } >"$transcript"

  smtp_send_transcript "$transcript" || die "SMTP send failed"
}

maybe_send_mail() {
  local subject="${SUBJECT_PREFIX} ${HOSTNAME_FQDN} ${STATUS} $(date +%F)"
  case "$MODE" in
    off) INFO_NOTES+=("Email sending disabled (mode=off)") ;;
    local) [[ -n "$TO_ADDR" ]] || die "mode=local requires --to"; send_mail_local "$subject" "$TEXT_REPORT" ;;
    smtp) send_mail_smtp "$subject" "$TEXT_REPORT" ;;
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
