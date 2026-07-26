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
# EXPECTED FAILURE MODES WITH THE TUNNEL DOWN (verified 2026-07-24)
#
# IPv4 -> EINVAL (errno 22). The kernel maps RTN_BLACKHOLE to -EINVAL, so a
# lookup that reaches the vpn table and matches the blackhole default fails at
# connect() with "Invalid argument". curl renders this as the generic
# "Couldn't connect to server" while still reporting its own "after 1 ms"
# timing, so curl's prose is not a usable signal. Read the errno.
#
# IPv6 -> ENETUNREACH, in BOTH tunnel states. This box has no v6 default
# route. Tunnel down, it has no global v6 address at all; tunnel up, tun0
# acquires one from Sonic but there is still no v6 default route. So v6
# packets die at ROUTING, before the filter chain, and the ip6tables REJECT on
# the fetcher uid HAS NEVER ACTUALLY FIRED. Keep that rule — it is correct
# defence in depth and becomes load-bearing the moment a v6 route appears —
# but do not read its presence as evidence that v6 is being blocked by it.
#
# WHAT ENETUNREACH ON IPv4 WOULD MEAN, AND WHAT IT DOES NOT. An earlier
# version of this script asserted that ENETUNREACH indicates "the vpn table
# has no route, blackhole missing". That was WRONG. Linux policy routing falls
# through to the NEXT RULE when a table lookup finds nothing, so an empty vpn
# table would send fetcher packets to the main table and out the datacenter IP
# — a LEAK presenting as a SUCCESSFUL connect, not as ENETUNREACH. That is
# precisely why the blackhole exists; if an empty table already failed closed,
# the blackhole would be redundant. ENETUNREACH on v4 would instead mean no
# usable route was found anywhere, i.e. the main-table default is gone too.
#
# CONSEQUENCE FOR ANYTHING DOWNSTREAM: two different errnos both mean "no
# egress" here, and which one a client surfaces depends on address family, on
# resolver ordering (which itself flips with tunnel state — see section F),
# and on how the client aggregates errors across a multi-address attempt.
# Do not infer tunnel state from fetch errors. Poll the route in the vpn
# table instead.
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
PROBE_TARGET="${WTM_PROBE_TARGET:-1.1.1.1}"    # v4 literal: route-get + probe fallback
PROBE_TIMEOUT="${WTM_PROBE_TIMEOUT:-15}"
CONTROL_UID="${WTM_CONTROL_UID:-12345}"        # a uid no ip rule matches
# The family probe needs a host with BOTH A and AAAA records, or the v6 half
# of the check is silently untested. example.com is dual-stack and stable.
FAMILY_HOST="${WTM_FAMILY_HOST:-example.com}"
FAMILY_PORT="${WTM_FAMILY_PORT:-443}"

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

info() { printf '  %s %-44s %s\n' '[info]' "$1" "${2:-}"; }

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

# Resolves a DUAL-STACK hostname and connects to every returned address
# separately, reporting the resolver's ordering and one errno per address.
#
# This supersedes the old single-address probe, which connected to a v4
# LITERAL and so could only ever exercise the v4 path. That was a near-miss
# rather than a design: had it used a hostname with AF_UNSPEC it would have
# reported a spurious failure on a healthy box, because the resolver puts v6
# first when the tunnel is down and every v6 address is unreachable here.
#
# Machine-readable lines (ORDER / RESULT / FIRST / SUMMARY4 / SUMMARY6) are
# parsed by the summary below; they are also meant to be human-readable.
FAMILY_PROBE_PY='
import errno, socket, sys, time

host = sys.argv[1]
port = int(sys.argv[2])
timeout = float(sys.argv[3])
fallback_ip = sys.argv[4] if len(sys.argv) > 4 else ""

FAM = {socket.AF_INET: "IPv4", socket.AF_INET6: "IPv6"}

def attempt(fam, name, sa):
    # socket() itself raises EAFNOSUPPORT on a kernel with no v6 stack, so it
    # must sit INSIDE the try. Leaving it outside crashed the probe after the
    # v4 rows but before the SUMMARY lines, which the caller then misread as
    # "probe skipped".
    s = None
    t0 = time.monotonic()
    try:
        s = socket.socket(fam, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(sa[:2] if fam == socket.AF_INET else sa)
        print("RESULT", name, sa[0], "CONNECTED", int((time.monotonic() - t0) * 1000))
        return "CONNECTED"
    except OSError as e:
        ms = int((time.monotonic() - t0) * 1000)
        if e.errno:
            code = errno.errorcode.get(e.errno, "E" + str(e.errno))
        else:
            code = "NOERRNO"
        print("RESULT", name, sa[0], code, ms)
        return code
    finally:
        if s is not None:
            s.close()

ordered = []
try:
    for idx, item in enumerate(socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)):
        fam, sa = item[0], item[4]
        name = FAM.get(fam, str(fam))
        print("ORDER", idx, name, sa[0])
        ordered.append((fam, name, sa))
except OSError as e:
    print("RESOLVE_FAIL", type(e).__name__, e)

if ordered:
    print("FIRST", ordered[0][1])
elif fallback_ip:
    print("FIRST", "IPv4-literal-fallback")
    ordered = [(socket.AF_INET, "IPv4", (fallback_ip, port))]

seen = {}
for fam, name, sa in ordered:
    seen.setdefault(name, []).append(attempt(fam, name, sa))

for name in ("IPv4", "IPv6"):
    got = seen.get(name)
    if not got:
        value = "NONE"
    elif "CONNECTED" in got:
        value = "CONNECTED"
    else:
        value = got[0]
    print("SUMMARY" + name[-1], value)
'

# ------------------------------------------------------------ arguments ---
# By default this script ALWAYS exits 0 (see the header): the snapshot was
# taken, and any verdict belongs to the human reading it. --status opts into
# a machine-readable exit code so a monitor can act on it without parsing
# prose. Parsing the summary text would be the same mistake as reading curl's
# error message instead of the errno.
#
#   exit 0    no failures, no indeterminates
#   exit N    N checks FAILED (capped at 125)
#   exit 100  no failures, but one or more checks were INDETERMINATE
#             ("could not measure" is not "fine" — that conflation is exactly
#             how a oneshot unit reported active for 17.5 hours with no floor)
EXIT_WITH_STATUS=no
case "${1:-}" in
    --status)
        EXIT_WITH_STATUS=yes ;;
    --help|-h)
        sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
        echo
        echo "usage: wtm-egress-check [--status]"
        exit 0 ;;
    "")
        ;;
    *)
        echo "wtm-egress-check: unknown argument '$1'" >&2
        echo "usage: wtm-egress-check [--status]" >&2
        exit 2 ;;
esac

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
printf '\n'
printf '# v6 rules are shown for completeness. There is deliberately no v6\n'
printf '# policy routing here; v6 is blocked by absence of a route (see E).\n'
run ip -6 rule list

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
printf '\n'
printf '# tun0 picks up a global v6 address from Sonic when the tunnel is up,\n'
printf '# even though no v6 DEFAULT ROUTE is installed. Presence of an address\n'
printf '# here is therefore not evidence that v6 egress works.\n'
run ip -6 -br addr show tun0

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
printf '\n'
printf '# The REJECT rule above only fires if a v6 packet survives routing.\n'
printf '# On this box it never has: there is no v6 default route in either\n'
printf '# tunnel state, so v6 dies earlier, with ENETUNREACH. If a default\n'
printf '# route ever appears below, that rule stops being inert and starts\n'
printf '# being the thing that blocks v6 — worth noticing when it happens.\n'
run ip -6 route show default
V6_DEFAULT=$(ip -6 route show default 2>/dev/null)
run ip -6 addr show scope global

# -------------------------------------------------------------- F: probes --
section "F. probes"
printf '  DNS resolves OUTSIDE the tunnel by design (loopback stub, priority-0\n'
printf '  local table), so a hostname still resolves with the tunnel down and\n'
printf '  the failure appears later, at connect.\n\n'
printf '  RESOLVER ORDERING FLIPS WITH TUNNEL STATE (observed 2026-07-24, same\n'
printf '  host, same target, minutes apart): tunnel DOWN returned both IPv6\n'
printf '  addresses first, tunnel UP returned both IPv4 first. Likely RFC 6724\n'
printf '  destination selection reacting to whether a global v6 SOURCE address\n'
printf '  exists on tun0 — inference, not measured. The practical effect is that\n'
printf '  with the tunnel down, the FIRST connect error a dual-stack client meets\n'
printf '  is v6 ENETUNREACH, not the v4 EINVAL from the blackhole.\n\n'

FAMILY_OUT=''
V4_RESULT=''
V6_RESULT=''
FIRST_FAMILY=''
FAMILY_STATE=skipped   # skipped | ok | crashed
if [ -n "$FETCHER_UID" ] && command -v python3 >/dev/null 2>&1; then
    printf '  $ as %s: resolve %s:%s, then connect to EVERY address separately\n' \
        "$FETCHER_USER" "$FAMILY_HOST" "$FAMILY_PORT"
    FAMILY_OUT=$(sudo -u "$FETCHER_USER" python3 -c "$FAMILY_PROBE_PY" \
        "$FAMILY_HOST" "$FAMILY_PORT" "$PROBE_TIMEOUT" "$PROBE_TARGET" 2>&1)
    printf '%s\n' "$FAMILY_OUT" | sed 's/^/    /'
    V4_RESULT=$(printf '%s\n' "$FAMILY_OUT" | awk '$1 == "SUMMARY4" {print $2; exit}')
    V6_RESULT=$(printf '%s\n' "$FAMILY_OUT" | awk '$1 == "SUMMARY6" {print $2; exit}')
    FIRST_FAMILY=$(printf '%s\n' "$FAMILY_OUT" | awk '$1 == "FIRST" {print $2; exit}')
    # Missing SUMMARY lines mean the probe died partway. That is NOT the same
    # as never running it, and must not be reported as if it were.
    if [ -z "$V4_RESULT" ] || [ -z "$V6_RESULT" ]; then
        FAMILY_STATE=crashed
        printf '\n  WARNING: the family probe produced no SUMMARY line — it exited\n'
        printf '  early. Results above are partial; treat the v4/v6 verdicts below\n'
        printf '  as unmeasured rather than as passes.\n'
    else
        FAMILY_STATE=ok
    fi
else
    printf '  family probe SKIPPED (no fetcher user, or python3 absent)\n'
fi
printf '\n'

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

# Presence of the rule is checked separately from whether it is doing anything.
if printf '%s\n' "$V6RULES" | grep -q -- "--uid-owner ${FETCHER_USER}\|--uid-owner ${FETCHER_UID}"; then
    if [ -n "$V6_DEFAULT" ]; then
        ck ok "ip6tables OUTPUT: fetcher REJECT" "present AND load-bearing (a v6 default route exists)"
    else
        ck ok "ip6tables OUTPUT: fetcher REJECT" "present but INERT — no v6 default route; v6 dies at routing"
    fi
else
    if [ -n "$V6_DEFAULT" ]; then
        ck fail "ip6tables OUTPUT: fetcher REJECT" "MISSING and a v6 default route exists — v6 can leak"
    else
        ck fail "ip6tables OUTPUT: fetcher REJECT" "not present (currently masked by absence of a v6 route)"
    fi
fi

# The empirical half: whatever the rules say, did v6 actually go anywhere?
case "$V6_RESULT" in
    CONNECTED)
        ck fail "IPv6 does not egress" "v6 CONNECTED — v4-only policy breached, LEAK" ;;
    ENETUNREACH)
        ck ok "IPv6 does not egress" "ENETUNREACH: no route, as expected on this box" ;;
    ECONNREFUSED|EACCES|EHOSTUNREACH)
        ck ok "IPv6 does not egress" "$V6_RESULT: blocked after routing — the REJECT rule is now firing" ;;
    EAFNOSUPPORT)
        ck ok "IPv6 does not egress" "no v6 stack in this kernel at all" ;;
    NONE)
        ck unknown "IPv6 does not egress" "$FAMILY_HOST returned no AAAA; set WTM_FAMILY_HOST to a dual-stack host" ;;
    '')
        if [ "$FAMILY_STATE" = crashed ]; then
            ck unknown "IPv6 does not egress" "family probe exited early — UNMEASURED"
        else
            ck unknown "IPv6 does not egress" "family probe skipped"
        fi ;;
    *)
        ck unknown "IPv6 does not egress" "unexpected result: $V6_RESULT" ;;
esac

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

if [ -n "$FIRST_FAMILY" ]; then
    info "resolver returns first" "$FIRST_FAMILY (expect IPv6 when down, IPv4 when up — not a fault either way)"
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

    case "$V4_RESULT" in
        CONNECTED) ck ok "IPv4 connect as $FETCHER_USER succeeds" ;;
        '')
            if [ "$FAMILY_STATE" = crashed ]; then
                ck unknown "IPv4 connect as $FETCHER_USER" "family probe exited early — UNMEASURED"
            else
                ck unknown "IPv4 connect as $FETCHER_USER" "family probe skipped"
            fi ;;
        *)         ck fail "IPv4 connect as $FETCHER_USER succeeds" "got $V4_RESULT with the tunnel up" ;;
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

    case "$V4_RESULT" in
        EINVAL)
            if [ -n "$CURL_CONNECT_MS" ] && [ "$CURL_CONNECT_MS" -lt 50 ]; then
                ck ok "IPv4 fails closed at blackhole" \
                   "EINVAL, curl connect ${CURL_CONNECT_MS}ms"
            else
                ck ok "IPv4 fails closed at blackhole" \
                   "EINVAL (no curl timing figure)"
            fi ;;
        CONNECTED)
            ck fail "IPv4 fails closed at blackhole" \
               "connect SUCCEEDED with the tunnel down — LEAK" ;;
        ENETUNREACH)
            # NOT "the blackhole is missing" — an empty vpn table would fall
            # through to main and LEAK instead. See the header.
            ck fail "IPv4 fails closed at blackhole" \
               "ENETUNREACH, not EINVAL — the blackhole did not answer. Check that the vpn blackhole AND the main default both exist" ;;
        '')
            if [ "$FAMILY_STATE" = crashed ]; then
                ck unknown "IPv4 fails closed at blackhole" "family probe exited early — UNMEASURED; curl said: $FETCHER_OUT"
            else
                ck unknown "IPv4 fails closed at blackhole" "family probe skipped; curl said: $FETCHER_OUT"
            fi ;;
        *)
            ck unknown "IPv4 fails closed at blackhole" "unexpected result: $V4_RESULT" ;;
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

if [ "$EXIT_WITH_STATUS" = yes ]; then
    if [ "$FAILS" -gt 0 ]; then
        [ "$FAILS" -gt 125 ] && exit 125
        exit "$FAILS"
    fi
    if [ "$UNKNOWNS" -gt 0 ]; then
        exit 100
    fi
fi

exit 0
