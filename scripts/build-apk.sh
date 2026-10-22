#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# build-apk.sh
# Descarga el APK de Brave para (variante, arquitectura) y genera los APKs
# parcheados (Estándar y/o AMOLED) junto con sus metadatos en JSON.
# ==============================================================================

BRAVE_VARIANT="${1:-Stable}"
ARCH="${2:-armv8}"
BRAVE_TAG="${3:-}"
THEME_MODE="${4:-all}"
APK_URL="${5:-}"

# Asegurar limpieza de certificados al salir (éxito o error)
cleanup_certs() {
  rm -rf certs
}
trap cleanup_certs EXIT

echo "=========================================================="
echo "==> Iniciando compilación de Brave Browser:"
echo "    Variante:     $BRAVE_VARIANT"
echo "    Arquitectura: $ARCH"
echo "    Tag Brave:    ${BRAVE_TAG:-'(desde URL manual)'}"
echo "    Tema(s):      $THEME_MODE"
echo "=========================================================="

# 1. Descarga de APK base
if [ -n "$APK_URL" ]; then
  echo "==> Descargando APK desde URL provista: $APK_URL"
  curl -fL -o input.apk "$APK_URL"
  RESOLVED_BRAVE_VERSION="manual-url"
else
  if [ -z "$BRAVE_TAG" ]; then
    echo "Error: BRAVE_TAG no fue proporcionado." >&2
    exit 1
  fi

  RESOLVED_BRAVE_VERSION="$BRAVE_TAG"
  echo "==> Resolviendo activo APK para tag '$BRAVE_TAG' y arch '$ARCH'..."

  ASSET_NAME=$(gh api "repos/brave/brave-browser/releases/tags/$BRAVE_TAG" | jq -r --arg arch "$ARCH" '
    .assets | map(select(.name | endswith(".apk"))) as $apks |
    (
      if $arch == "armv8" then
        ($apks | map(select(.name | test("arm64.*universal|arm64"; "i"))) | first | .name)
      elif $arch == "armv7" then
        ($apks | map(select((.name | test("monoarm|[0-9]-arm|arm"; "i")) and (.name | test("arm64"; "i") | not))) | first | .name)
      elif $arch == "universal" then
        ($apks | map(select(.name | test("universal"; "i"))) | first | .name)
      else
        empty
      end
    ) // ($apks | first | .name) // empty
  ')

  if [ -z "$ASSET_NAME" ] || [ "$ASSET_NAME" = "null" ]; then
    echo "Error: No se encontró ningún activo APK compatible para arquitectura '$ARCH' en release '$BRAVE_TAG'." >&2
    exit 1
  fi

  echo "Descargando '$ASSET_NAME' de brave/brave-browser..."
  gh release download "$BRAVE_TAG" --repo brave/brave-browser --pattern "$ASSET_NAME" --output input.apk
fi

ls -lh input.apk

# 2. Configurar Keystore si está disponible
KEYSTORE_ARGS=()
SIGNING_STATUS="debug"
if [ -n "${KEYSTORE_BASE64:-}" ]; then
  echo "Configurando keystore personalizado desde secreto..."
  mkdir -p certs
  echo "$KEYSTORE_BASE64" | base64 -d > certs/signing.keystore
  KEYSTORE_ARGS=(
    --keystore certs/signing.keystore
    --keystore-password "${KEYSTORE_PASSWORD:-}"
    --keystore-entry-alias "${KEYSTORE_ALIAS:-}"
    --keystore-entry-password "${KEYSTORE_ENTRY_PASSWORD:-${KEYSTORE_PASSWORD:-}}"
  )
  SIGNING_STATUS="custom"
fi

# 3. Integrations argument
MERGE_ARGS=()
if [ -f "tools/integrations.apk" ]; then
  if java -jar tools/cli.jar patch --help 2>&1 | grep -q -- "--merge"; then
    MERGE_ARGS=("--merge" "tools/integrations.apk")
  fi
fi

# 4. Preflight de parches compatibles
PACKAGE_NAME="com.brave.browser"
case "$BRAVE_VARIANT" in
  Beta) PACKAGE_NAME="com.brave.browser_beta" ;;
  Nightly) PACKAGE_NAME="com.brave.browser_nightly" ;;
esac

echo "=========================================================="
echo "==> Inspeccionando parches compatibles para '$PACKAGE_NAME'..."
echo "=========================================================="
AVAILABLE_PATCHES=$(java -jar tools/cli.jar list-patches --patches tools/patches.jar --filter-package "$PACKAGE_NAME" 2>/dev/null || true)
if [ -z "$AVAILABLE_PATCHES" ]; then
  AVAILABLE_PATCHES=$(java -jar tools/cli.jar list-patches --patches tools/patches.jar 2>/dev/null || true)
fi

echo "$AVAILABLE_PATCHES"

has_patch() {
  local query="$1"
  echo "$AVAILABLE_PATCHES" | grep -qi "$query"
}

# 5. Lista de parches base
BASE_PATCH_ARGS=()
BASE_APPLIED_NAMES=()

if has_patch "Origin"; then
  echo "Parche 'Brave Origin' disponible."
  BASE_PATCH_ARGS+=(-e "Brave Origin")
  BASE_APPLIED_NAMES+=("Brave Origin")
fi

if has_patch "Startup Performance"; then
  echo "Parche 'Brave Startup Performance Optimization' disponible."
  BASE_PATCH_ARGS+=(-e "Brave Startup Performance Optimization")
  BASE_APPLIED_NAMES+=("Brave Startup Performance Optimization")
fi

WALLPAPER_FILE="assets/wallpaper.png"
if [ -f "$WALLPAPER_FILE" ] && has_patch "Custom NTP wallpaper"; then
  echo "Parche 'Custom NTP wallpaper' disponible con assets/wallpaper.png."
  BASE_PATCH_ARGS+=(-e "Custom NTP wallpaper" -O customWallpaper="$WALLPAPER_FILE")
  BASE_APPLIED_NAMES+=("Custom NTP wallpaper")
fi

if has_patch "four-column"; then
  echo "Parche 'Brave NTP four-column tiles' disponible."
  BASE_PATCH_ARGS+=(-e "Brave NTP four-column tiles")
  BASE_APPLIED_NAMES+=("Brave NTP four-column tiles")
fi

# Función de ejecución de parcheo
patch_apk() {
  local target_apk="$1"
  shift
  local extra_args=("$@")

  echo "=========================================================="
  echo "==> Compilando: $target_apk"
  echo "=========================================================="

  java -jar tools/cli.jar patch \
    --patches tools/patches.jar \
    "${BASE_PATCH_ARGS[@]}" \
    ${extra_args[@]+"${extra_args[@]}"} \
    ${MERGE_ARGS[@]+"${MERGE_ARGS[@]}"} \
    ${KEYSTORE_ARGS[@]+"${KEYSTORE_ARGS[@]}"} \
    -o "$target_apk" \
    input.apk

  ls -lh "$target_apk"
}

GENERATED_APKS_JSON=()

# 6. Compilar Estándar si corresponde
if [ "$THEME_MODE" = "all" ] || [ "$THEME_MODE" = "standard" ]; then
  STD_APK="brave-${BRAVE_VARIANT}-${ARCH}-patched.apk"
  echo "==> Procesando variante Estándar..."
  patch_apk "$STD_APK"

  STD_HASH=$(sha256sum "$STD_APK" | awk '{print $1}')
  echo "${STD_HASH}  ${STD_APK}" > "${STD_APK}.sha256"

  PATCHES_JSON=$(printf '%s\n' "${BASE_APPLIED_NAMES[@]}" | jq -R . | jq -s .)

  GENERATED_APKS_JSON+=(
    $(jq -cn \
      --arg file "$STD_APK" \
      --arg theme "standard" \
      --arg sha "$STD_HASH" \
      --argjson patches "$PATCHES_JSON" \
      '{filename: $file, theme: $theme, sha256: $sha, applied_patches: $patches}')
  )
fi

# 7. Compilar AMOLED si corresponde
if [ "$THEME_MODE" = "all" ] || [ "$THEME_MODE" = "amoled" ]; then
  AMOLED_APK="brave-${BRAVE_VARIANT}-${ARCH}-amoled-patched.apk"
  echo "==> Procesando variante 🖤 AMOLED..."

  AMOLED_EXTRA=()
  AMOLED_APPLIED=("${BASE_APPLIED_NAMES[@]}")

  if has_patch "AMOLED"; then
    echo "Parche 'Brave AMOLED theme' disponible."
    AMOLED_EXTRA+=(-e "Brave AMOLED theme" -O backgroundColor="#000000")
    AMOLED_APPLIED+=("Brave AMOLED theme")
  else
    echo "Aviso: 'Brave AMOLED theme' no encontrado en el bundle."
  fi

  patch_apk "$AMOLED_APK" "${AMOLED_EXTRA[@]}"

  AMOLED_HASH=$(sha256sum "$AMOLED_APK" | awk '{print $1}')
  echo "${AMOLED_HASH}  ${AMOLED_APK}" > "${AMOLED_APK}.sha256"

  AMOLED_PATCHES_JSON=$(printf '%s\n' "${AMOLED_APPLIED[@]}" | jq -R . | jq -s .)

  GENERATED_APKS_JSON+=(
    $(jq -cn \
      --arg file "$AMOLED_APK" \
      --arg theme "amoled" \
      --arg sha "$AMOLED_HASH" \
      --argjson patches "$AMOLED_PATCHES_JSON" \
      '{filename: $file, theme: $theme, sha256: $sha, applied_patches: $patches}')
  )
fi

# 8. Guardar metadata estructurada en JSON
ALL_APKS_JSON=$(printf '%s\n' "${GENERATED_APKS_JSON[@]}" | jq -s .)

METADATA_FILE="metadata-${BRAVE_VARIANT}-${ARCH}.json"
jq -cn \
  --arg variant "$BRAVE_VARIANT" \
  --arg arch "$ARCH" \
  --arg brave_version "$RESOLVED_BRAVE_VERSION" \
  --arg signing_status "$SIGNING_STATUS" \
  --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --argjson apks "$ALL_APKS_JSON" \
  '{
    variant: $variant,
    architecture: $arch,
    brave_version: $brave_version,
    signing_status: $signing_status,
    timestamp: $timestamp,
    apks: $apks
  }' > "$METADATA_FILE"

echo "=========================================================="
echo "==> Metadatos guardados en $METADATA_FILE:"
cat "$METADATA_FILE" | jq .
echo "=========================================================="
