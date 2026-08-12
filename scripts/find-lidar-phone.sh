#!/usr/bin/env bash
# Discover lidar capture phones on the local network via Bonjour and print curl commands.
set -euo pipefail

SERVICE_TYPE="_http._tcp"
BROWSE_SECONDS="${BROWSE_SECONDS:-4}"
RESOLVE_SECONDS="${RESOLVE_SECONDS:-3}"

if ! command -v dns-sd >/dev/null 2>&1; then
  echo "dns-sd is required (macOS Bonjour). This script only runs on a Mac." >&2
  exit 1
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/lidar-find.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

browse_log="$tmpdir/browse.log"
resolve_log="$tmpdir/resolve.log"

echo "Browsing for ${SERVICE_TYPE} on local. (${BROWSE_SECONDS}s)…"
dns-sd -B "$SERVICE_TYPE" local. >"$browse_log" 2>&1 &
browse_pid=$!
sleep "$BROWSE_SECONDS"
kill "$browse_pid" 2>/dev/null || true
wait "$browse_pid" 2>/dev/null || true

# Unique instance names from "Add" lines (everything after "_http._tcp.").
instances=()
while IFS= read -r line; do
  [[ -n "$line" ]] && instances+=("$line")
done < <(
  awk '
    $2 == "Add" {
      line = $0
      sub(/^.*_http\._tcp\.[ \t]*/, "", line)
      gsub(/[ \t]+$/, "", line)
      if (line != "") print line
    }
  ' "$browse_log" | sort -u
)

if ((${#instances[@]} == 0)); then
  echo "No ${SERVICE_TYPE} services found."
  echo "Make sure the lidar app is open on the phone, Local Network is allowed, and you're on the same Wi‑Fi."
  exit 1
fi

echo
echo "Found ${#instances[@]} HTTP service(s). Checking which ones speak lidar (/health)…"

declare -a lidar_names=()
declare -a lidar_hosts=()
declare -a lidar_ports=()

resolve_service() {
  local name="$1"
  : >"$resolve_log"
  dns-sd -L "$name" "$SERVICE_TYPE" local. >"$resolve_log" 2>&1 &
  local pid=$!
  sleep "$RESOLVE_SECONDS"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  # Example: iPhone._http._tcp.local. can be reached at TEDWARD.local.:8080 (interface 12)
  local reached
  reached="$(grep -E 'can be reached at ' "$resolve_log" | head -n1 || true)"
  if [[ -z "$reached" ]]; then
    return 1
  fi

  local hostport host port
  hostport="$(sed -E 's/.*can be reached at ([^ ]+).*/\1/' <<<"$reached")"
  hostport="${hostport%.}" # trim trailing dot after .local.:8080 → .local:8080 mishandle
  # dns-sd prints "TEDWARD.local.:8080" — strip the dot before the colon.
  hostport="$(sed -E 's/\.:/:/' <<<"$hostport")"
  host="${hostport%%:*}"
  port="${hostport##*:}"
  if [[ -z "$host" || -z "$port" || "$host" == "$port" ]]; then
    return 1
  fi

  printf '%s\t%s\n' "$host" "$port"
}

for name in "${instances[@]}"; do
  if ! resolved="$(resolve_service "$name")"; then
    echo "  • $name — could not resolve"
    continue
  fi
  host="$(cut -f1 <<<"$resolved")"
  port="$(cut -f2 <<<"$resolved")"
  health="$(curl -fsS -m 2 "http://${host}:${port}/health" 2>/dev/null || true)"
  if [[ "$health" == ok* ]]; then
    echo "  • $name — lidar at ${host}:${port}"
    lidar_names+=("$name")
    lidar_hosts+=("$host")
    lidar_ports+=("$port")
  else
    echo "  • $name — ${host}:${port} (not lidar)"
  fi
done

echo

if ((${#lidar_names[@]} == 0)); then
  echo "No lidar servers responded to /health."
  echo "Open the app on the phone (foreground), allow Local Network, then try again."
  exit 1
fi

selected=0
if ((${#lidar_names[@]} > 1)); then
  echo "Select a phone:"
  for i in "${!lidar_names[@]}"; do
    printf '  [%d] %s  (%s:%s)\n' "$((i + 1))" "${lidar_names[$i]}" "${lidar_hosts[$i]}" "${lidar_ports[$i]}"
  done
  echo
  while true; do
    read -r -p "Number: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#lidar_names[@]})); then
      selected=$((choice - 1))
      break
    fi
    echo "Enter a number between 1 and ${#lidar_names[@]}."
  done
  echo
else
  echo "Using: ${lidar_names[0]} (${lidar_hosts[0]}:${lidar_ports[0]})"
  echo
fi

host="${lidar_hosts[$selected]}"
port="${lidar_ports[$selected]}"
base="http://${host}:${port}"

cat <<EOF
Commands for ${lidar_names[$selected]}:

  # Health check
  curl ${base}/health

  # Capture JPEG + depth TIFF as a ZIP (also saves to camera roll on the phone)
  curl ${base}/capture -o capture.zip

  # Same, with a timestamped filename
  curl ${base}/capture -o "capture-\$(date +%Y%m%d-%H%M%S).zip"
EOF
