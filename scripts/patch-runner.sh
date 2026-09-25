#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script: patch-runner.sh
# Descripción: Ejecutor unificado de parcheo y firma con Morphe CLI para
#              cualquier aplicación (Brave, YouTube, Reddit, etc.).
# ==============================================================================

# Argumentos posicionales
INPUT_APK="${1:-}"
OUTPUT_APK="${2:-}"
CLI_JAR="${3:-tools/cli.jar}"
PATCHES_JAR="${4:-tools/patches.jar}"
INTEGRATIONS_APK="${5:-tools/integrations.apk}"

if [[ -z "${INPUT_APK}" || -z "${OUTPUT_APK}" ]]; then
  echo "Uso: $0 <input_apk> <output_apk> [cli.jar] [patches.jar] [integrations.apk]"
  exit 1
fi

KEYSTORE_ARGS=()

# Si se proporcionó el secreto KEYSTORE_BASE64 en las variables de entorno
if [[ -n "${KEYSTORE_BASE64:-}" ]]; then
  echo "Configurando keystore personalizado..."
  mkdir -p certs
  echo "$KEYSTORE_BASE64" | base64 -d > certs/signing.keystore

  KEYSTORE_ARGS=(
    --keystore certs/signing.keystore
    --keystore-password "${KEYSTORE_PASSWORD:-}"
    --keystore-entry-alias "${KEYSTORE_ALIAS:-}"
    --keystore-entry-password "${KEYSTORE_ENTRY_PASSWORD:-${KEYSTORE_PASSWORD:-}}"
  )
else
  echo "No se detectó KEYSTORE_BASE64. Morphe CLI usará el keystore de debug predeterminado."
fi

# Compatibilidad con integraciones: solo incluir --merge si el archivo existe y el CLI lo soporta
MERGE_ARGS=()
if [[ -f "$INTEGRATIONS_APK" ]]; then
  if java -jar "$CLI_JAR" patch --help 2>&1 | grep -q -- "--merge"; then
    echo "Integrations APK detectado y soportado por el CLI, aplicando flag --merge..."
    MERGE_ARGS=(--merge "$INTEGRATIONS_APK")
  else
    echo "Integrations APK disponible; Morphe CLI empaqueta las integraciones dentro del bundle de parches."
  fi
fi

echo "Iniciando proceso de parcheo..."
java -jar "$CLI_JAR" patch \
  --patches "$PATCHES_JAR" \
  ${MERGE_ARGS[@]+"${MERGE_ARGS[@]}"} \
  ${KEYSTORE_ARGS[@]+"${KEYSTORE_ARGS[@]}"} \
  --out "$OUTPUT_APK" \
  "$INPUT_APK"

# Limpieza del keystore desencriptado del runner
rm -rf certs
echo "Parcheo completado: $OUTPUT_APK"
