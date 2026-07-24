#!/usr/bin/env bash
#
# wtm-egress-check — one-shot, read-only snapshot of the web-to-markdown
# fetcher's VPN egress state on the Oracle box (instance-20260410-1115).
#
# READ-ONLY BY CONTRACT. This script must never start, stop, restart, add,
# delete or flush anything. If you are ever tempted to make it repair what it
# finds, write a second script. Its entire value is that its output can be
# trusted as a description of the state you were already in, rather than the
# state your check just produced.
#
# It prints a timestamp at the top and at the bottom, and the delta between
# them. Anything that can move underneath it — the on-demand tunnel trigger,
# an idle-down timer, openvpn's ping-restart after 50s, or a systemctl you
# ran seconds ago — can make a snapshot straddle a transition. If the delta
# is large, or a background actor could plausibly have fired inside it, run
# it again before believing the picture.
#
# Requires root: reads iptables and runs probes as the fetcher uid. It
# refuses to run unprivileged rather than emit a partial snapshot, because a
# partial snapshot is the exact failure mode this script exists to prevent.
#
# Exit status is 0 whenever the snapshot was taken, regardless of what it
# found. Do not gate anything on it. Read the SUMMARY.
#
# ---------------------------------------------------------------------------
# ON THE EXPECTED FAILURE MODE WITH THE TUNNEL DOWN (verified 2026-07-24)
#
# The fetcher's fail-closed error is EINVAL (errno 22), NOT ENETUNREACH.
# The kernel maps RTN_BLACKHOLE to -EINVAL, so a lookup that reaches the vpn
# table and matches the blackhole default returns "Invalid argument" at
# connect() time. curl renders that as the generic "Couldn't connect to
# server", while still reporting its own "after 1 ms" timing.
#
# These two are NOT interchangeable and the difference is diagnostic:
#   EINVAL       -> blackhole present and governing. Correct fail-closed.
#   ENETUNREACH  -> vpn table has NO route at all. Also fails closed, but by
#                   accident rather than by design; the blackhole is missing.
# Anything downstream that classifies egress errors must not key on
# ENETUNREACH alone.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C   # EPOCHREALTIME decimal separator, and stable ip/iptables output

# ---------------------------------------------------------------- config ---
# Box-specific expectations. Override via environment for a different host.
FETCHER_USER="${WTM_FETCHER_USER:-fetcher}"
VPN_TABLE="${WTM_VPN_TABLE:-vpn}"
ROUTING_UNIT="${WTM_ROUTING_UNIT:-wtm-vpn-routing.service}"
OPENVPN_UNIT="${WTM_OPENVPN_UNIT:-wtm-openvpn.service}"
ORACLE_EXIT_IP="${WTM_ORACLE_EXIT_IP:-144.24.44.81}"
MAIN_GW="${WTM_MAIN_GW:-10.0.0.1}"
MAIN_IF="${WTM_MAIN_IF:-enp0s6}"
SONIC_PREFIX="${WTM_SONIC_PREFIX:-192.184.}"   # observed pool range, not authoritative
PROBE_URL="${WTM_PROBE_URL:-https://api.ipify.org}"
PROBE_TARGET="${WTM_PROBE_TARGET:-1.1.1.1}"
PROBE_TIMEOUT="${WTM_PROBE_TIMEOUT:-15}"
CONTROL_UID="${WTM_CONTROL_UID:-12345}"        # a uid no ip rule matches

# --------------------------------------------------------------- helpers ---
FAILS=0
UNKNOWNS=0

section() { printf '\n=== %s ===\n' "$*"; }

# Display-only. Capture the status into a variable IMMEDIATELY: `[` is itself
# a command and running it resets PIPESTATUS, so testing the array and then
# re-expanding it in printf reports the status of the test, not of the
# command. That bug made failing commands report "exited 0".
run() {
    printf '$ %s\n' "$*"
    "$@" 2>&1 | sed 's/^/  /'
    local rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        printf '  (command exited %s)\n' "$rc"
    fi
}

ck() {    # ck ok|fail|unknown <label> [detail...]
    local st=$1 label=$2
    shift 2
    local mark
    case "$st" in
        ok)   mark='[ ok ]' ;;
        fail) mark='[FAIL]' ; FAILS=$((FAILS + 1)) ;;
        *)    mark='[ ?? ]' ; UNKNOWNS=$((UNKNOWNS + 1)) ;;
    esac
    printf '  %s %-44s %s\n' "$mark" "$label" "$*"
}

PROBE_OUT=''; PROBE_RC=0; PROBE_MS=0
timed_probe() {
    local label=$1
    shift
    local t0 t1
    t0=${EPOCHREALTIME/./}
    PROBE_OUT=$("$@" 2>&1)
    PROBE_RC=$?
    t1=${EPOCHREALTIME/./}
    PROBE_MS=$(( (t1 - t0) / 1000 ))
    printf '  %-26s rc=%-3s %6s ms  %s\n' \
        "$label" "$PROBE_RC" "$PROBE_MS" "$(printf '%s' "$PROBE_OUT" | tr '\n' ' ')"
}

# Reports the raw errno of a connect() attempt, rather than leaving the
# failure to be inferred from a client's prose. This is the authoritative
# fail-closed signal; the curl probe below exists to report the exit IP.
ERRNO_PROBE_PY='
import errno, socket, sys
s = socket.socket()
s.settimeout(5)
try:
    s.connect((sys.argv[1], 443))
    print("OK connected")
except OSError as e:
    print("ERR", e.errno, errno.errorcode.get(e.errno, "UNKNOWN"), "-", e.strerror)
'

# ------------------------------------------------------------ preflight ---
if [ -z "${EPOCHREALTIME:-}" ]; then
    echo "wtm-egress-check: needs bash 5.0+ (EPOCHREALTIME)." >&2
    exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "wtm-egress-check: must run as root (iptables reads + fetcher probes)." >&2
    echo "  try: sudo wtm-egress-check" >&2
    exit 2
fi

STARTED_AT=$(date -Is)
STARTED_EPOCH=${EPOCHREALTIME/./}

printf '===============================================================\n'
printf ' wtm-egress-check   started %s\n' "$STARTED_AT"
printf ' host %s   read-only snapshot, changes nothing\n' "$(hostname)"
printf '===============================================================\n'

if FETCHER_UID=$(id -u "$FETCHER_USER" 2>/dev/null); then
    printf '\nfetcher user: %s  uid %s\n' "$FETCHER_USER" "$FETCHER_UID"
else
    FETCHER_UID=''
    printf '\nfetcher user: %s  NOT FOUND\n' "$FETCHER_USER"
fi

# Detect tunnel state from the route rather than from tun0 or unit status.
# The route is what decides whether packets go anywhere; Type=notify reports
# ready roughly six seconds before the tunnel actually carries traffic.
VPN_ROUTES=$(ip route show table "$VPN_TABLE" 2>&1)
if printf '%s\n' "$VPN_ROUTES" | grep -qE '^default .*dev tun[0-9]'; then
    MODE=UP
else
    MODE=DOWN
fi
printf 'tunnel state (by route in table %s): %s\n' "$VPN_TABLE" "$MODE"

# --------------------------------------------------------------- A: rules --
section "A. ip rules (expect 999 uidrange, 1000 fwmark, both -> $VPN_TABLE)"
run ip rule list

# -------------------------------------------------------------- B: routes --
section "B. routes"
printf '$ ip route show table %s\n' "$VPN_TABLE"
printf '%s\n' "$VPN_ROUTES" | sed 's/^/  /'
printf '\n'
run ip route show default
printf '\n'
printf '# connect()-time lookup as the kernel would do it for each identity.\n'
printf '# This is the check the fwmark design failed: a mangle OUTPUT mark is\n'
printf '# applied per packet, after the source address is already chosen.\n'
printf '# With the tunnel DOWN, uid %s is EXPECTED to give "Invalid argument"\n' "${FETCHER_UID:-?}"
printf '# — that is the blackhole answering (RTN_BLACKHOLE -> -EINVAL), not a\n'
printf '# rejected command. The uid %s control below proves the distinction.\n' "$CONTROL_UID"

CONTROL_GET=''
UID_GET=''
if [ -n "$FETCHER_UID" ]; then
    UID_GET=$(ip route get "$PROBE_TARGET" uid "$FETCHER_UID" 2>&1)
    run ip route get "$PROBE_TARGET" uid "$FETCHER_UID"
fi
CONTROL_GET=$(ip route get "$PROBE_TARGET" uid "$CONTROL_UID" 2>&1)
run ip route get "$PROBE_TARGET" uid "$CONTROL_UID"
run ip route get "$PROBE_TARGET" uid 0

# --------------------------------------------------------------- C: units --
section "C. systemd units"
OPENVPN_AGO=-1
for unit in "$ROUTING_UNIT" "$OPENVPN_UNIT"; do
    active=$(systemctl is-active "$unit" 2>&1)
    enabled=$(systemctl is-enabled "$unit" 2>&1)
    entered=$(systemctl show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null)
    ago='-'
    ago_s=-1
    if [ -n "$entered" ]; then
        if entered_epoch=$(date -d "$entered" +%s 2>/dev/null); then
            ago_s=$(( $(date +%s) - entered_epoch ))
            ago="${ago_s}s ago"
        fi
    fi
    [ "$unit" = "$OPENVPN_UNIT" ] && OPENVPN_AGO=$ago_s
    printf '  %-26s active=%-12s enabled=%-12s entered=%s (%s)\n' \
        "$unit" "$active" "$enabled" "${entered:--}" "$ago"
done

# Only warn about the reconnect window when there is actually a recent start
# to straddle. Printing it unconditionally trains the reader to skip it.
if [ "$OPENVPN_AGO" -ge 0 ] && [ "$OPENVPN_AGO" -lt 30 ]; then
    printf '\n  WARNING: %s entered active %ss ago. This snapshot may sit\n' \
        "$OPENVPN_UNIT" "$OPENVPN_AGO"
    printf '  inside the ~1-5s reconnect window in which the vpn table holds only\n'
    printf '  the blackhole and the fetcher correctly fails closed. Re-run.\n'
fi

# --------------------------------------------------------------- D: link ---
section "D. tun0"
run ip -br link show tun0
run ip -4 -br addr show tun0

# Find the token after "inet" rather than a fixed field number: `ip -o addr`
# prefixes a device index, `ip -br addr` does not, and a net30-topology tun0
# renders as "inet A peer B/32" while subnet topology renders as "inet A/22".
TUN_ADDR=$(ip -4 -o addr show dev tun0 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "inet") {print $(i+1); exit}}' \
    | cut -d/ -f1)

# ------------------------------------------------------------ E: firewall --
section "E. packet marking / v6 posture"
run iptables -t mangle -S OUTPUT
run ip6tables -S OUTPUT

# -------------------------------------------------------------- F: probes --
section "F. probes"
printf '  DNS resolves OUTSIDE the tunnel by design (loopback stub, priority-0\n'
printf '  local table). So with the tunnel down a hostname still resolves and the\n'
printf '  failure appears at connect, as EINVAL from the blackhole in about 1ms.\n\n'

ERRNO_NAME=''
if [ -n "$FETCHER_UID" ] && command -v python3 >/dev/null 2>&1; then
    timed_probe "connect() as $FETCHER_USER" \
        sudo -u "$FETCHER_USER" python3 -c "$ERRNO_PROBE_PY" "$PROBE_TARGET"
    ERRNO_OUT=$PROBE_OUT
    ERRNO_NAME=$(printf '%s\n' "$ERRNO_OUT" | awk '$1 == "ERR" {print $3; exit}')
    printf '%s\n' "$ERRNO_OUT" | grep -q '^OK connected' && ERRNO_NAME=CONNECTED
else
    ERRNO_OUT=''
    printf '  connect() as %s        SKIPPED (no user, or python3 absent)\n' "$FETCHER_USER"
fi

if [ -n "$FETCHER_UID" ]; then
    timed_probe "curl as $FETCHER_USER" \
        sudo -u "$FETCHER_USER" curl -sS --max-time "$PROBE_TIMEOUT" "$PROBE_URL"
    FETCHER_OUT=$PROBE_OUT; FETCHER_RC=$PROBE_RC; FETCHER_MS=$PROBE_MS
else
    FETCHER_OUT=''; FETCHER_RC=-1; FETCHER_MS=0
    printf '  curl as %s             SKIPPED (user not found)\n' "$FETCHER_USER"
fi

timed_probe "curl as root" curl -sS --max-time "$PROBE_TIMEOUT" "$PROBE_URL"
ROOT_OUT=$PROBE_OUT; ROOT_RC=$PROBE_RC

# ------------------------------------------------------------- G: summary --
section "G. SUMMARY  (mode: $MODE)"

RULES=$(ip rule list 2>/dev/null)
MANGLE=$(iptables -t mangle -S OUTPUT 2>/dev/null)
V6RULES=$(ip6tables -S OUTPUT 2>/dev/null)
MAINDEF=$(ip route show default 2>/dev/null)

printf '\n  Floor (must hold in BOTH modes):\n'

if [ -n "$FETCHER_UID" ]; then
    ck ok "fetcher user exists" "uid $FETCHER_UID"
else
    ck fail "fetcher user exists" "user '$FETCHER_USER' not found"
fi

if [ -n "$FETCHER_UID" ] && \
   printf '%s\n' "$RULES" | grep -qE "uidrange ${FETCHER_UID}-${FETCHER_UID} lookup ${VPN_TABLE}"; then
    ck ok "ip rule: uidrange -> $VPN_TABLE"
else
    ck fail "ip rule: uidrange -> $VPN_TABLE" "missing; source selection will use the main table"
fi

if printf '%s\n' "$RULES" | grep -qE "fwmark 0x1 lookup ${VPN_TABLE}"; then
    ck ok "ip rule: fwmark 0x1 -> $VPN_TABLE" "second layer"
else
    ck fail "ip rule: fwmark 0x1 -> $VPN_TABLE" "defence-in-depth layer missing"
fi

if printf '%s\n' "$VPN_ROUTES" | grep -q 'blackhole default'; then
    ck ok "vpn table: blackhole default present"
else
    ck fail "vpn table: blackhole default present" "fetches can leak out the datacenter IP"
fi

if printf '%s\n' "$MAINDEF" | grep -q "via ${MAIN_GW} dev ${MAIN_IF}"; then
    ck ok "main table default intact" "via $MAIN_GW dev $MAIN_IF"
else
    ck fail "main table default intact" "cloudflared return path may be asymmetric"
fi

if printf '%s\n' "$MANGLE" | grep -q -- "--uid-owner ${FETCHER_USER}\|--uid-owner ${FETCHER_UID}"; then
    ck ok "mangle OUTPUT: fetcher mark rule"
else
    ck fail "mangle OUTPUT: fetcher mark rule" "not present"
fi

if printf '%s\n' "$V6RULES" | grep -q -- "--uid-owner ${FETCHER_USER}\|--uid-owner ${FETCHER_UID}"; then
    ck ok "ip6tables OUTPUT: fetcher REJECT" "deliberate v4-only policy"
else
    ck fail "ip6tables OUTPUT: fetcher REJECT" "not present"
fi

if [ "$(systemctl is-active "$ROUTING_UNIT" 2>&1)" = active ]; then
    ck ok "$ROUTING_UNIT active"
else
    ck fail "$ROUTING_UNIT active" "the fail-closed floor is down"
fi

if [ "$(systemctl is-enabled "$ROUTING_UNIT" 2>&1)" = enabled ]; then
    ck ok "$ROUTING_UNIT enabled at boot"
else
    ck fail "$ROUTING_UNIT enabled at boot" "no floor after a reboot"
fi

if [ "$(systemctl is-enabled "$OPENVPN_UNIT" 2>&1)" = disabled ]; then
    ck ok "$OPENVPN_UNIT disabled at boot" "on-demand only"
else
    ck fail "$OPENVPN_UNIT disabled at boot" "expected disabled"
fi

if printf '%s\n' "$ROOT_OUT" | grep -q "^${ORACLE_EXIT_IP}$"; then
    ck ok "root exits Oracle IP" "$ORACLE_EXIT_IP"
elif [ "$ROOT_RC" -ne 0 ]; then
    ck unknown "root exits Oracle IP" "probe failed rc=$ROOT_RC: $ROOT_OUT"
else
    ck fail "root exits Oracle IP" "got '$ROOT_OUT', expected $ORACLE_EXIT_IP"
fi

# The control makes the uid route-get self-validating: without it, an
# "Invalid argument" on the fetcher uid is ambiguous between "the blackhole
# answered" and "this iproute2 does not accept uid for route get".
CONTROL_OK=no
if printf '%s\n' "$CONTROL_GET" | grep -q "dev ${MAIN_IF}"; then
    CONTROL_OK=yes
    ck ok "route-get uid control (uid $CONTROL_UID)" "selector supported, falls to main table"
else
    ck unknown "route-get uid control (uid $CONTROL_UID)" \
       "unexpected: $CONTROL_GET — treat uid route-get results as unreliable"
fi

if [ "$MODE" = UP ]; then
    printf '\n  Tunnel UP expectations:\n'

    if printf '%s\n' "$VPN_ROUTES" | grep -qE '^default .*dev tun[0-9].*metric 1( |$)'; then
        ck ok "vpn table: tunnel default at metric 1" "wins over the blackhole"
    else
        ck fail "vpn table: tunnel default at metric 1" "present but metric unexpected"
    fi

    if [ -n "$TUN_ADDR" ]; then
        ck ok "tun0 has an address" "$TUN_ADDR"
    else
        ck fail "tun0 has an address" "route says up but no v4 address"
    fi

    if [ "$CONTROL_OK" = yes ]; then
        if printf '%s\n' "$UID_GET" | grep -q 'dev tun[0-9]'; then
            ck ok "route-get uid $FETCHER_UID -> tunnel"
        else
            ck fail "route-get uid $FETCHER_UID -> tunnel" "got: $UID_GET"
        fi
    fi

    case "$ERRNO_NAME" in
        CONNECTED) ck ok "connect() as $FETCHER_USER succeeds" ;;
        '')        ck unknown "connect() as $FETCHER_USER" "probe skipped" ;;
        *)         ck fail "connect() as $FETCHER_USER succeeds" "$ERRNO_OUT" ;;
    esac

    case "$FETCHER_OUT" in
        "${SONIC_PREFIX}"*)
            ck ok "fetcher exits VPN IP" "$FETCHER_OUT (${FETCHER_MS}ms)" ;;
        *)
            if [ "$FETCHER_RC" -ne 0 ]; then
                ck fail "fetcher exits VPN IP" "probe failed rc=$FETCHER_RC: $FETCHER_OUT"
            else
                ck fail "fetcher exits VPN IP" "got '$FETCHER_OUT', expected ${SONIC_PREFIX}x.x"
            fi ;;
    esac

    # Sonic assigns a public address straight to tun0 with no NAT, so the
    # observed exit address should equal tun0's own address. A mismatch means
    # something is translating, or the probe left by an unexpected path.
    if [ -n "$TUN_ADDR" ] && [ -n "$FETCHER_OUT" ]; then
        if [ "$TUN_ADDR" = "$FETCHER_OUT" ]; then
            ck ok "exit IP == tun0 address" "no NAT, as expected"
        else
            ck fail "exit IP == tun0 address" "tun0=$TUN_ADDR exit=$FETCHER_OUT"
        fi
    else
        ck unknown "exit IP == tun0 address" "one side unavailable"
    fi
else
    printf '\n  Tunnel DOWN expectations (fail-closed):\n'

    if printf '%s\n' "$VPN_ROUTES" | grep -qE '^default'; then
        ck fail "vpn table: no tunnel default" "a stale default is present"
    else
        ck ok "vpn table: no tunnel default" "blackhole governs"
    fi

    if [ "$CONTROL_OK" = yes ]; then
        if printf '%s\n' "$UID_GET" | grep -q 'Invalid argument'; then
            ck ok "route-get uid $FETCHER_UID -> blackhole" "EINVAL, as designed"
        elif printf '%s\n' "$UID_GET" | grep -q "dev ${MAIN_IF}"; then
            ck fail "route-get uid $FETCHER_UID -> blackhole" \
               "fetcher would route out the datacenter IP — LEAK"
        else
            ck unknown "route-get uid $FETCHER_UID -> blackhole" "got: $UID_GET"
        fi
    fi

    # errno is authoritative here. curl's prose is not: it renders EINVAL as
    # the generic "Couldn't connect to server".
    CURL_CONNECT_MS=$(printf '%s\n' "$FETCHER_OUT" \
        | sed -n 's/.*after \([0-9][0-9]*\) ms.*/\1/p' | head -n1)

    case "$ERRNO_NAME" in
        EINVAL)
            if [ -n "$CURL_CONNECT_MS" ] && [ "$CURL_CONNECT_MS" -lt 50 ]; then
                ck ok "fetcher fails closed at blackhole" \
                   "EINVAL, curl connect ${CURL_CONNECT_MS}ms"
            else
                ck ok "fetcher fails closed at blackhole" \
                   "EINVAL (no curl timing figure)"
            fi ;;
        ENETUNREACH)
            ck fail "fetcher fails closed at blackhole" \
               "ENETUNREACH means the vpn table has NO route — blackhole missing" ;;
        CONNECTED)
            ck fail "fetcher fails closed" "connect SUCCEEDED with tunnel down — LEAK" ;;
        '')
            ck unknown "fetcher fails closed" "errno probe skipped; curl said: $FETCHER_OUT" ;;
        *)
            ck unknown "fetcher fails closed" "unexpected errno: $ERRNO_OUT" ;;
    esac

    if [ "$FETCHER_RC" -eq 0 ]; then
        ck fail "curl as fetcher fails" "SUCCEEDED with tunnel down: '$FETCHER_OUT' — LEAK"
    else
        ck ok "curl as fetcher fails" "rc=$FETCHER_RC in ${FETCHER_MS}ms wall"
    fi
fi

# ------------------------------------------------------------------ tail ---
FINISHED_AT=$(date -Is)
FINISHED_EPOCH=${EPOCHREALTIME/./}
ELAPSED_MS=$(( (FINISHED_EPOCH - STARTED_EPOCH) / 1000 ))

printf '\n===============================================================\n'
printf ' checks failed: %s   indeterminate: %s\n' "$FAILS" "$UNKNOWNS"
printf ' started  %s\n' "$STARTED_AT"
printf ' finished %s   (%s ms elapsed)\n' "$FINISHED_AT" "$ELAPSED_MS"
printf ' If anything could have started or stopped the tunnel inside that\n'
printf ' window, this snapshot straddles a transition. Run it again.\n'
printf '===============================================================\n'

exit 0
