#!/usr/bin/env bash
set -euo pipefail

echo "### RUN.SH SMART SOFAR START ###"

if [ -f /usr/lib/bashio/bashio.sh ]; then
  # shellcheck disable=SC1091
  source /usr/lib/bashio/bashio.sh
  logi(){ bashio::log.info "$1"; }
  logw(){ bashio::log.warning "$1"; }
  loge(){ bashio::log.error "$1"; }
else
  logi(){ echo "[INFO] $1"; }
  logw(){ echo "[WARN] $1"; }
  loge(){ echo "[ERROR] $1"; }
fi

logi "Smart Sofar: init..."

OPTS="/data/options.json"
if [ ! -f "$OPTS" ]; then
  loge "options.json introuvable dans /data. Stop."
  exit 1
fi

tmp="/data/flows.tmp.json"

jq_str_or() {
  local jq_expr="$1"
  local fallback="$2"
  jq -r "($jq_expr // \"\") | if (type==\"string\" and length>0) then . else \"$fallback\" end" "$OPTS"
}

jq_int_or() {
  local jq_expr="$1"
  local fallback="$2"
  jq -r "($jq_expr // $fallback) | tonumber" "$OPTS" 2>/dev/null || echo "$fallback"
}

SERIAL_PORT="$(jq -r '.serial_port // ""' "$OPTS")"
MODBUS_SLAVE_ID="$(jq_int_or '.modbus_slave_id' 1)"
MODBUS_BAUDRATE="$(jq_int_or '.modbus_baudrate' 9600)"

MQTT_HOST="$(jq_str_or '.mqtt_host' '')"
MQTT_PORT="$(jq_int_or '.mqtt_port' 1883)"
MQTT_USER="$(jq -r '.mqtt_user // ""' "$OPTS")"
MQTT_PASS="$(jq -r '.mqtt_pass // ""' "$OPTS")"
MQTT_PREFIX="$(jq_str_or '.mqtt_prefix' 'sofar')"

TZ_MODE="$(jq -r '.timezone_mode // "UTC"' "$OPTS")"
TZ_CUSTOM="$(jq -r '.timezone_custom // "UTC"' "$OPTS")"

if [ "$TZ_MODE" = "CUSTOM" ]; then
  ADDON_TIMEZONE="$TZ_CUSTOM"
else
  ADDON_TIMEZONE="$TZ_MODE"
fi

if [ -z "${ADDON_TIMEZONE:-}" ] || [ "$ADDON_TIMEZONE" = "null" ]; then
  ADDON_TIMEZONE="UTC"
fi

export SERIAL_PORT
export MODBUS_SLAVE_ID
export MODBUS_BAUDRATE
export MQTT_HOST
export MQTT_PORT
export MQTT_USER
export MQTT_PASS
export MQTT_PREFIX
export ADDON_TIMEZONE

logi "Serial port: ${SERIAL_PORT:-<empty>}"
logi "Modbus slave ID: ${MODBUS_SLAVE_ID}"
logi "Modbus baudrate: ${MODBUS_BAUDRATE}"
logi "MQTT: ${MQTT_HOST:-<empty>}:${MQTT_PORT} (user: ${MQTT_USER:-<none>})"
logi "MQTT prefix: ${MQTT_PREFIX}"
logi "Timezone: ${ADDON_TIMEZONE}"

if [ -z "${SERIAL_PORT}" ]; then
  loge "serial_port vide. Renseigne-le dans la config add-on."
  exit 1
fi

if [ -z "${MQTT_HOST}" ]; then
  loge "mqtt_host vide. Renseigne-le dans la config add-on."
  exit 1
fi

mkdir -p /data/smart-sofar

ADDON_FLOWS_VERSION="$(cat /addon/flows_version.txt 2>/dev/null || echo '0.1.0')"
INSTALLED_VERSION="$(cat /data/flows_version.txt 2>/dev/null || echo '')"

if [ ! -f /data/flows.json ] || [ "$INSTALLED_VERSION" != "$ADDON_FLOWS_VERSION" ]; then
  logi "Mise à jour flows : (installé: ${INSTALLED_VERSION:-aucun}) -> (addon: $ADDON_FLOWS_VERSION)"
  cp /addon/flows.json /data/flows.json
  echo "$ADDON_FLOWS_VERSION" > /data/flows_version.txt
  logi "flows.json mis à jour vers v$ADDON_FLOWS_VERSION"
else
  logi "flows.json à jour (v$ADDON_FLOWS_VERSION), conservation des flows utilisateur"
fi

# ============================================================
# Patch Modbus client
# ============================================================
if jq -e '.[] | select(.type=="modbus-client" and .name=="Sofar Modbus Serial")' /data/flows.json >/dev/null 2>&1; then
  jq \
    --arg serial_port "$SERIAL_PORT" \
    --arg serial_baudrate "$MODBUS_BAUDRATE" \
    --arg unit_id "$MODBUS_SLAVE_ID" \
    '
    map(
      if .type=="modbus-client" and .name=="Sofar Modbus Serial"
      then
        .serialPort = $serial_port
        | .serialBaudrate = $serial_baudrate
        | .unit_id = $unit_id
      else .
      end
    )
    ' /data/flows.json > "$tmp" && mv "$tmp" /data/flows.json

  logi "Modbus client patched: port=${SERIAL_PORT} baud=${MODBUS_BAUDRATE} slave=${MODBUS_SLAVE_ID}"
else
  logw "Noeud modbus-client 'Sofar Modbus Serial' introuvable dans flows.json"
fi

# ============================================================
# Patch MQTT broker
# ============================================================
if jq -e '.[] | select(.type=="mqtt-broker" and .name=="HA MQTT Broker")' /data/flows.json >/dev/null 2>&1; then
  jq \
    --arg host "$MQTT_HOST" \
    --arg port "$MQTT_PORT" \
    --arg user "$MQTT_USER" \
    '
    map(
      if .type=="mqtt-broker" and .name=="HA MQTT Broker"
      then
        .broker = $host
        | .port = $port
        | .user = $user
      else .
      end
    )
    ' /data/flows.json > "$tmp" && mv "$tmp" /data/flows.json

  logi "MQTT broker patched in flows.json"
else
  logw "Aucun mqtt-broker nommé 'HA MQTT Broker' trouvé dans flows.json"
fi

# ============================================================
# Patch MQTT topics prefix in function nodes
# ============================================================
jq \
  --arg prefix "$MQTT_PREFIX" '
  map(
    if .type=="function" and .name=="MERGE state"
    then .func = (
"function deepMerge(target, source) {\n\
  for (const key of Object.keys(source)) {\n\
    if (source[key] && typeof source[key] === '\''object'\'' && !Array.isArray(source[key])) {\n\
      if (!target[key] || typeof target[key] !== '\''object'\'' || Array.isArray(target[key])) {\n\
        target[key] = {};\n\
      }\n\
      deepMerge(target[key], source[key]);\n\
    } else {\n\
      target[key] = source[key];\n\
    }\n\
  }\n\
  return target;\n\
}\n\
\n\
let state = flow.get('\''sofar_state'\'') || {};\n\
deepMerge(state, msg.payload || {});\n\
\n\
state.last_update = new Date().toISOString();\n\
state.connection = '\''serial_modbus'\'';\n\
state.protocol = '\''modbus_rtu'\'';\n\
state.model_hint = '\''Sofar HYD6000EP'\'';\n\
state.slave_id = " + $prefix + ";\n\
state.available = true;\n\
\n\
flow.set('\''sofar_state'\'', state);\n\
\n\
msg.topic = '\''" )
    else .
    end
  )
  ' /data/flows.json >/dev/null 2>&1 || true

# Repatch propre des functions topics via substitutions simples ciblées
jq \
  --arg prefix "$MQTT_PREFIX" '
  map(
    if .type=="function" and .name=="MERGE state"
    then .func |= gsub("msg.topic = '\\''sofar/1/state'\\'';"; "msg.topic = '\\''" + $prefix + "/1/state'\\'';")
    elif .type=="function" and .name=="ONLINE"
    then .func |= gsub("msg.topic = '\\''sofar/1/availability'\\'';"; "msg.topic = '\\''" + $prefix + "/1/availability'\\'';")
    else .
    end
  )
  ' /data/flows.json > "$tmp" && mv "$tmp" /data/flows.json

# Patch MQTT will topic
jq \
  --arg prefix "$MQTT_PREFIX" '
  map(
    if .type=="mqtt-broker" and .name=="HA MQTT Broker"
    then .willTopic = ($prefix + "/1/availability")
    else .
    end
  )
  ' /data/flows.json > "$tmp" && mv "$tmp" /data/flows.json

logi "MQTT topics patched with prefix: ${MQTT_PREFIX}"

# ============================================================
# flows_cred.json
# ============================================================
if [ -f /data/flows_cred.json ]; then
  rm -f /data/flows_cred.json
  logw "Ancien flows_cred.json supprimé"
fi

BROKER_ID="$(jq -r '.[] | select(.type=="mqtt-broker" and .name=="HA MQTT Broker") | .id' /data/flows.json 2>/dev/null || true)"

if [ -n "${BROKER_ID}" ]; then
  jq -n \
    --arg id "$BROKER_ID" \
    --arg user "$MQTT_USER" \
    --arg pass "$MQTT_PASS" \
    '{($id): {"user": $user, "password": $pass}}' \
    > /data/flows_cred.json

  logi "flows_cred.json créé avec succès"
else
  logw "Impossible de créer flows_cred.json: broker MQTT introuvable"
fi

logi "Starting Node-RED sur le port 1892..."
exec node-red --userDir /data --settings /addon/settings.js
