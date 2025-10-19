#!/usr/bin/env bash
set -euo pipefail

# skylinkvpn.sh
# - Deploys a Cloud Run service (skylinkvpn) using provided Docker images (no build)
# - Keeps service running (no auto-delete)
# - Rotates keys every 6 hours and posts new config URI to Telegram channel(s)
# - Uses path "/skylinkvpnchannel" (encoded as %2Fskylinkvpnchannel in URIs)
#
# Requirements:
# - gcloud logged in and project selected
# - uuidgen, curl, base64, sha256sum (or openssl fallback)
# - Optional: .env file with TELEGRAM_TOKEN and TELEGRAM_CHAT_ID(s)

# ===== Logging & error handler =====
LOG_FILE="/tmp/skylinkvpn_$(date +%s).log"
touch "$LOG_FILE"
on_err() {
  local rc=$?
  echo "" | tee -a "$LOG_FILE"
  echo "❌ ERROR: Command failed (exit $rc) at line $LINENO: ${BASH_COMMAND}" | tee -a "$LOG_FILE" >&2
  echo "—— LOG (last 80 lines) ——" >&2
  tail -n 80 "$LOG_FILE" >&2 || true
  echo "📄 Log File: $LOG_FILE" >&2
  exit $rc
}
trap on_err ERR

# ===== UI/colors (optional) =====
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RESET=$'\e[0m'; BOLD=$'\e[1m'
  C_CYAN=$'\e[38;5;44m'; C_BLUE=$'\e[38;5;33m'
  C_GREEN=$'\e[38;5;46m'; C_ORG=$'\e[38;5;214m'
  C_GREY=$'\e[38;5;245m'; C_RED=$'\e[38;5;196m'
else
  RESET= BOLD= C_CYAN= C_BLUE= C_GREEN= C_ORG= C_GREY= C_RED=
fi

hr(){ printf "${C_GREY}%s${RESET}\n" "──────────────────────────────────────────────"; }
banner(){ printf "\n${C_BLUE}${BOLD}╔════════════════════════════════════════════════╗${RESET}\n"; printf "${C_BLUE}${BOLD}║${RESET}  %s${RESET}\n" "$(printf "%-46s" "$1")"; printf "${C_BLUE}${BOLD}╚════════════════════════════════════════════════╝${RESET}\n"; }
ok(){ printf "${C_GREEN}✔${RESET} %s\n" "$1"; }
warn(){ printf "${C_ORG}⚠${RESET} %s\n" "$1"; }
kv(){ printf "   ${C_GREY}%s${RESET}  %s\n" "$1" "$2"; }

printf "\n${C_CYAN}${BOLD}🚀 SkyLinkVPN — Cloud Run Deploy + Key-Rotate${RESET}\n"
hr

# ===== helpers =====
json_escape(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ===== Step 1: Telegram config =====
banner "Step 1 — Telegram Setup (optional)"
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
TELEGRAM_CHAT_IDS="${TELEGRAM_CHAT_IDS:-${TELEGRAM_CHAT_ID:-}}"

if [[ ( -z "${TELEGRAM_TOKEN}" || -z "${TELEGRAM_CHAT_IDS}" ) && -f .env ]]; then
  set -a; source ./.env; set +a
fi

read -rp "🤖 Telegram Bot Token (enter to skip): " _tk || true
[[ -n "${_tk:-}" ]] && TELEGRAM_TOKEN="$_tk"
if [[ -z "${TELEGRAM_TOKEN:-}" ]]; then
  warn "Telegram token empty; Telegram notifications disabled."
else
  ok "Telegram token set."
fi

read -rp "👥 Telegram Chat ID(s) comma-separated (enter to skip): " _ids || true
[[ -n "${_ids:-}" ]] && TELEGRAM_CHAT_IDS="${_ids// /}"

CHAT_ID_ARR=()
IFS=',' read -r -a CHAT_ID_ARR <<< "${TELEGRAM_CHAT_IDS:-}" || true

tg_send(){
  local text="$1" RM=""
  if [[ -z "${TELEGRAM_TOKEN:-}" || ${#CHAT_ID_ARR[@]} -eq 0 ]]; then return 0; fi
  for _cid in "${CHAT_ID_ARR[@]}"; do
    curl -s -S -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d "chat_id=${_cid}" \
      --data-urlencode "text=${text}" \
      -d "parse_mode=HTML" >>"$LOG_FILE" 2>&1 || true
    ok "Telegram sent → ${_cid}"
  done
}

# ===== Step 2: GCP Project =====
banner "Step 2 — GCP Project"
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "$PROJECT" ]]; then
  err "No active gcloud project. Run: gcloud config set project <PROJECT_ID>"
  exit 1
fi
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')" || true
ok "Project Loaded: ${PROJECT} (${PROJECT_NUMBER})"

# ===== Step 3: Protocol selection =====
banner "Step 3 — Select Protocol"
echo "  1) Trojan WS"
echo "  2) VLESS WS"
echo "  3) VLESS gRPC"
echo "  4) VMess WS"
read -rp "Choose [1-4, default 1]: " _opt || true
case "${_opt:-1}" in
  2) PROTO="vless-ws"   ; IMAGE="docker.io/n4pro/vl:latest"        ;;
  3) PROTO="vless-grpc" ; IMAGE="docker.io/n4pro/vlessgrpc:latest" ;;
  4) PROTO="vmess-ws"   ; IMAGE="docker.io/n4pro/vmess:latest"     ;;
  *) PROTO="trojan-ws"  ; IMAGE="docker.io/n4pro/tr:latest"        ;;
esac
ok "Protocol selected: ${PROTO}"

# ===== Step 4: Region =====
banner "Step 4 — Region"
echo "1) Singapore (asia-southeast1)"
echo "2) US - Iowa (us-central1)"
echo "3) Indonesia (asia-southeast2)"
echo "4) Japan (asia-northeast1)"
read -rp "Choose [1-4, default 2]: " _r || true
case "${_r:-2}" in
  1) REGION="asia-southeast1";;
  3) REGION="asia-southeast2";;
  4) REGION="asia-northeast1";;
  *) REGION="us-central1";;
esac
ok "Region: ${REGION}"

# ===== Step 5: Resources =====
banner "Step 5 — Resources"
read -rp "CPU [1/2/4/6, default 2]: " _cpu || true
CPU="${_cpu:-2}"
read -rp "Memory [512Mi/1Gi/2Gi(default)/4Gi/8Gi]: " _mem || true
MEMORY="${_mem:-2Gi}"
ok "CPU/Mem: ${CPU} vCPU / ${MEMORY}"

# ===== Step 6: Service name & basics =====
banner "Step 6 — Service Name & Timezone"
SERVICE="skylinkvpn"
TIMEOUT="${TIMEOUT:-3600}"
PORT="${PORT:-8080}"
ok "Service: ${SERVICE}"

export TZ="Asia/Yangon"
START_EPOCH="$(date +%s)"
fmt_dt(){ date -d @"$1" "+%d.%m.%Y %I:%M %p"; }
START_LOCAL="$(fmt_dt "$START_EPOCH")"
kv "Start:" "${START_LOCAL}"

# ===== Enable APIs (best-effort) =====
banner "Step 7 — Enable APIs"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com --quiet >>"$LOG_FILE" 2>&1 || true
ok "Requested enabling Cloud Run & Cloud Build APIs (if not already)."

# ===== Deploy to Cloud Run =====
banner "Step 8 — Deploying to Cloud Run"
echo "Deploying ${SERVICE} to ${REGION} ..."
gcloud run deploy "$SERVICE" \
  --image="$IMAGE" \
  --platform=managed \
  --region="$REGION" \
  --memory="$MEMORY" \
  --cpu="$CPU" \
  --timeout="$TIMEOUT" \
  --allow-unauthenticated \
  --port="$PORT" \
  --min-instances=1 \
  --quiet >>"$LOG_FILE" 2>&1
ok "gcloud run deploy finished."

# ===== Result / Canonical host =====
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')" || true
CANONICAL_HOST="${SERVICE}-${PROJECT_NUMBER}.${REGION}.run.app"
URL_CANONICAL="https://${CANONICAL_HOST}"
banner "Result"
kv "URL:" "${URL_CANONICAL}"

# ===== Initial key values (will be rotated) =====
# generate initial keys now
gen_short_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    echo "$(date +%s | sha256sum | cut -c1-8)"
  else
    # openssl fallback
    echo "$(date +%s | openssl dgst -sha256 | sed 's/^.* //g' | cut -c1-8)"
  fi
}

TROJAN_PASS="Trojan-$(gen_short_hash)"
VLESS_UUID="$(uuidgen || cat /proc/sys/kernel/random/uuid)"
VLESS_UUID_GRPC="$(uuidgen || cat /proc/sys/kernel/random/uuid)"
VMESS_UUID="$(uuidgen || cat /proc/sys/kernel/random/uuid)"

# helper to build vmess base64 URI
make_vmess_ws_uri(){
  local host="$1"
  local json=$(cat <<JSON
{"v":"2","ps":"SkyLinkVMess","add":"vpn.googleapis.com","port":"443","id":"${VMESS_UUID}","aid":"0","scy":"zero","net":"ws","type":"none","host":"${host}","path":"/skylinkvpnchannel","tls":"tls","sni":"vpn.googleapis.com","alpn":"http/1.1","fp":"randomized"}
JSON
)
  echo -n "$json" | base64 | tr -d '\n' | sed 's/^/vmess:\/\//'
}

# build current URI based on chosen protocol
build_uri(){
  case "$PROTO" in
    trojan-ws)
      URI="trojan://${TROJAN_PASS}@vpn.googleapis.com:443?path=%2Fskylinkvpnchannel&security=tls&host=${CANONICAL_HOST}&type=ws#SkyLink-Trojan"
      ;;
    vless-ws)
      URI="vless://${VLESS_UUID}@vpn.googleapis.com:443?path=%2Fskylinkvpnchannel&security=tls&encryption=none&host=${CANONICAL_HOST}&type=ws#SkyLink-Vless-WS"
      ;;
    vless-grpc)
      URI="vless://${VLESS_UUID_GRPC}@vpn.googleapis.com:443?mode=gun&security=tls&encryption=none&type=grpc&serviceName=n4-grpc&sni=${CANONICAL_HOST}#SkyLink-VLESS-gRPC"
      ;;
    vmess-ws)
      URI="$(make_vmess_ws_uri "${CANONICAL_HOST}")"
      ;;
    *)
      URI=""
      ;;
  esac
}

# build initial URI and notify
build_uri
banner "Deploy Complete — Notification"
NOTIFY_MSG=$(cat <<EOF
✅ <b>SkyLinkVPN Deploy Success</b>
━━━━━━━━━━━━━━━━━━
🌍 <b>Region:</b> ${REGION}
⚙️ <b>Protocol:</b> ${PROTO}
🔗 <b>URL:</b> ${URL_CANONICAL}
🔑 <b>Initial Config URI:</b>
<pre><code>${URI}</code></pre>
🕒 <b>Start:</b> ${START_LOCAL}
━━━━━━━━━━━━━━━━━━
EOF
)
tg_send "${NOTIFY_MSG}"

printf "\n${C_GREEN}${BOLD}✨ SkyLinkVPN deployed — service running at ${URL_CANONICAL}${RESET}\n"
printf "${C_GREY}📄 Log: ${LOG_FILE}${RESET}\n"
hr

# ===== Key rotation function =====
rotate_keys(){
  # generate new keys
  TROJAN_PASS="Trojan-$(gen_short_hash)"
  VLESS_UUID="$(uuidgen || cat /proc/sys/kernel/random/uuid)"
  VLESS_UUID_GRPC="$(uuidgen || cat /proc/sys/kernel/random/uuid)"
  VMESS_UUID="$(uuidgen || cat /proc/sys/kernel/random/uuid)"

  # rebuild URI with new keys
  build_uri

  # notify via Telegram
  if [[ -n "${TELEGRAM_TOKEN:-}" && ${#CHAT_ID_ARR[@]} -gt 0 ]]; then
    ROT_MSG=$(cat <<EOF
🔁 <b>SkyLinkVPN Key Rotated</b>
━━━━━━━━━━━━━━━━━━
🕒 <b>Time:</b> $(date +"%d.%m.%Y %I:%M %p")
🔑 <b>New Config URI:</b>
<pre><code>${URI}</code></pre>
━━━━━━━━━━━━━━━━━━
EOF
)
    tg_send "${ROT_MSG}"
  fi

  # write current keys to local log for owner (optional)
  {
    echo "===== Key rotation at $(date) ====="
    echo "TROJAN_PASS=${TROJAN_PASS}"
    echo "VLESS_UUID=${VLESS_UUID}"
    echo "VLESS_UUID_GRPC=${VLESS_UUID_GRPC}"
    echo "VMESS_UUID=${VMESS_UUID}"
    echo "URI=${URI}"
    echo
  } >>"$LOG_FILE"
  ok "Keys rotated and notified."
}

# ===== Start auto-rotation loop (run in background) =====
# Immediately send initial keys (already sent above), then rotate every 6 hours
(
  while true; do
    sleep 6h
    rotate_keys
  done
) &

ok "Auto-rotate background loop started (every 6 hours)."

# ===== Final info for operator =====
banner "Info / Next Steps"
kv "Service URL:" "${URL_CANONICAL}"
kv "Protocol:" "${PROTO}"
kv "Current Config URI:" "${URI}"
kv "To stop auto-rotate:" "Kill this script process or remove background loop (ps/kill)"
kv "To manually rotate keys:" "Run: rotate_keys (source the script and call the function) - or re-run script"

echo
ok "If you're running in terminal, consider: nohup ./skylinkvpn.sh & >/dev/null 2>&1 &"
ok "Manual delete (if needed): gcloud run services delete ${SERVICE} --region=${REGION} --quiet"

# End of script
