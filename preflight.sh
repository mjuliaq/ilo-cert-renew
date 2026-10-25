#!/bin/bash
# preflight.sh — Verify ilo-cert-renew installation before first run.
# Exit 0: all checks passed. Exit 1: one or more checks failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/ilo-cert-renew.conf"
NETRC_FILE="${SCRIPT_DIR}/.netrc"

PASS=0
FAIL=0
WARN=0

ok()      { echo "  [OK]   $*"; PASS=$((PASS+1)); }
fail()    { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
warn()    { echo "  [WARN] $*"; WARN=$((WARN+1)); }
section() { echo; echo "=== $* ==="; }

# ─── System tools ─────────────────────────────────────────────────────────────
section "System tools"

# bash 4.0+ (arrays, [[ ]])
BASH_MAJOR="${BASH_VERSINFO[0]}"
if [[ "$BASH_MAJOR" -ge 4 ]]; then
  ok "bash ${BASH_VERSION} (>= 4.0 required)"
else
  fail "bash ${BASH_VERSION} is too old — bash 4.0+ required"
fi

# Required binaries
for cmd in certbot openssl curl awk logger; do
  if command -v "$cmd" &>/dev/null; then
    ok "$cmd found ($(command -v "$cmd"))"
  else
    fail "$cmd not found — install it before running the script"
  fi
done

# GNU date (-d flag)
if date -d "1 day ago" +%s &>/dev/null 2>&1; then
  ok "date supports GNU syntax (-d flag)"
else
  fail "date does not support -d flag — GNU coreutils required (on macOS: brew install coreutils)"
fi

# ─── certbot dns-rfc2136 plugin ───────────────────────────────────────────────
section "certbot dns-rfc2136 plugin"

if certbot plugins 2>/dev/null | grep -q "dns-rfc2136"; then
  ok "dns-rfc2136 plugin available"
else
  fail "dns-rfc2136 plugin not found — install python3-certbot-dns-rfc2136"
fi

# ─── Config file ──────────────────────────────────────────────────────────────
section "Config file (${CONFIG_FILE})"

if [[ ! -f "$CONFIG_FILE" ]]; then
  fail "Config file not found: ${CONFIG_FILE}"
  fail "  Copy ilo-cert-renew.conf.example to ilo-cert-renew.conf and edit it"
else
  ok "Config file exists"

  PERMS=$(stat -c "%a" "$CONFIG_FILE")
  if [[ "$PERMS" == "600" || "$PERMS" == "400" ]]; then
    ok "Config permissions: ${PERMS}"
  else
    fail "Config permissions ${PERMS} are too open — run: chmod 600 ${CONFIG_FILE}"
  fi

  # shellcheck source=/dev/null
  source "$CONFIG_FILE" 2>/dev/null || true

  for var in ILO_HOST RENEW_DAYS CERTBOT_CREDENTIALS CSR_COUNTRY CSR_STATE CSR_CITY CSR_ORG CSR_ORG_UNIT; do
    if [[ -n "${!var:-}" ]]; then
      ok "${var} = ${!var}"
    else
      fail "${var} is not set in the config file"
    fi
  done
fi

# ─── certbot credentials file ─────────────────────────────────────────────────
section "certbot credentials file"

if [[ -n "${CERTBOT_CREDENTIALS:-}" ]]; then
  if [[ -f "$CERTBOT_CREDENTIALS" ]]; then
    ok "Credentials file exists: ${CERTBOT_CREDENTIALS}"
    CRED_PERMS=$(stat -c "%a" "$CERTBOT_CREDENTIALS")
    if [[ "$CRED_PERMS" == "600" || "$CRED_PERMS" == "400" ]]; then
      ok "Credentials file permissions: ${CRED_PERMS}"
    else
      warn "Credentials file permissions ${CRED_PERMS} — certbot may reject it; run: chmod 600 ${CERTBOT_CREDENTIALS}"
    fi
    for key in dns_rfc2136_server dns_rfc2136_name dns_rfc2136_secret; do
      if grep -q "^${key}" "$CERTBOT_CREDENTIALS" 2>/dev/null; then
        ok "${key} present"
      else
        fail "${key} missing from ${CERTBOT_CREDENTIALS}"
      fi
    done
  else
    fail "Credentials file not found: ${CERTBOT_CREDENTIALS}"
    fail "  See README.md — BIND / certbot credentials file section"
  fi
else
  warn "CERTBOT_CREDENTIALS not set — skipping credentials file checks"
fi

# ─── .netrc file ──────────────────────────────────────────────────────────────
section ".netrc file (${NETRC_FILE})"

if [[ ! -f "$NETRC_FILE" ]]; then
  fail ".netrc not found: ${NETRC_FILE}"
  fail "  Create it: machine <ilo-host> login <user> password <pass>"
else
  ok ".netrc exists"

  NR_PERMS=$(stat -c "%a" "$NETRC_FILE")
  if [[ "$NR_PERMS" == "600" || "$NR_PERMS" == "400" ]]; then
    ok ".netrc permissions: ${NR_PERMS}"
  else
    fail ".netrc permissions ${NR_PERMS} are too open — run: chmod 600 ${NETRC_FILE}"
  fi

  if [[ -n "${ILO_HOST:-}" ]]; then
    ILO_USER=$(awk '{for(i=1;i<=NF;i++){if($i=="machine")cur=$(i+1); if(cur=="'"${ILO_HOST}"'" && $i=="login"){print $(i+1);exit}}}' "$NETRC_FILE")
    ILO_PASS=$(awk '{for(i=1;i<=NF;i++){if($i=="machine")cur=$(i+1); if(cur=="'"${ILO_HOST}"'" && $i=="password"){print $(i+1);exit}}}' "$NETRC_FILE")

    if [[ -n "$ILO_USER" ]]; then
      ok "Username found for ${ILO_HOST}: ${ILO_USER}"
    else
      fail "No 'login' field found for machine ${ILO_HOST} in .netrc"
    fi

    if [[ -n "$ILO_PASS" ]]; then
      ok "Password found for ${ILO_HOST} (non-empty)"
    else
      fail "No 'password' field found for machine ${ILO_HOST} in .netrc"
    fi
  else
    warn "ILO_HOST not set — skipping .netrc credential check"
  fi
fi

# ─── iLO reachability ─────────────────────────────────────────────────────────
section "iLO reachability"

if [[ -n "${ILO_HOST:-}" ]]; then
  if curl -sk --max-time 5 "https://${ILO_HOST}/redfish/v1/" -o /dev/null; then
    ok "iLO Redfish endpoint reachable: https://${ILO_HOST}/redfish/v1/"
  else
    fail "Cannot reach https://${ILO_HOST}/redfish/v1/ (check network / firewall)"
  fi
else
  warn "ILO_HOST not set — skipping reachability check"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo
echo "────────────────────────────────────────"
echo "  Passed : ${PASS}"
echo "  Warned : ${WARN}"
echo "  Failed : ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
  echo "  Fix the items above before running ilo-cert-renew"
  exit 1
else
  echo "  All checks passed. Ready to run ilo-cert-renew"
  exit 0
fi
