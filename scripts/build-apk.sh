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

  # Nombres reales publicados por Brave:
  #   BraveMonoarm64.apk      -> solo arm64-v8a
  #   BraveMonoarm.apk        -> solo armeabi-v7a
  #   Bravearm64Universal.apk -> APK universal (todas las ABI)
  # Se prioriza el nombre exacto y se usa un patrón como red de seguridad.
  ASSET_NAME=$(gh api "repos/brave/brave-browser/releases/tags/$BRAVE_TAG" | jq -r --arg arch "$ARCH" '
    [.assets[].name | select(endswith(".apk"))] as $apks |
    (
      if $arch == "armv8" then ["BraveMonoarm64.apk", "Bravearm64Universal.apk"]
      elif $arch == "armv7" then ["BraveMonoarm.apk"]
      elif $arch == "universal" then ["Bravearm64Universal.apk"]
      else [] end
    ) as $preferred |
    (
      [$preferred[] as $p | $apks[] | select(. == $p)] | first
    ) //
    (
      if $arch == "armv8" then
        ([$apks[] | select(test("arm64"; "i")) | select(test("universal"; "i") | not)] | first)
      elif $arch == "armv7" then
        ([$apks[] | select(test("arm"; "i")) | select(test("arm64"; "i") | not) | select(test("x86"; "i") | not)] | first)
      elif $arch == "universal" then
        ([$apks[] | select(test("universal"; "i"))] | first)
      else empty end
    ) // ""
  ')

  if [ -z "$ASSET_NAME" ] || [ "$ASSET_NAME" = "null" ]; then
    echo "Error: no se encontró ningún APK para la arquitectura '$ARCH' en la release '$BRAVE_TAG'." >&2
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
  if [ -z "${KEYSTORE_PASSWORD:-}" ] || [ -z "${KEYSTORE_ALIAS:-}" ]; then
    echo "Error: KEYSTORE_BASE64 requiere también KEYSTORE_PASSWORD y KEYSTORE_ALIAS." >&2
    exit 1
  fi

  echo "Configurando keystore personalizado desde secreto..."
  mkdir -p certs
  printf '%s' "$KEYSTORE_BASE64" | base64 -d > certs/signing.keystore
  KEYSTORE_ARGS=(
    --keystore certs/signing.keystore
    --keystore-password "${KEYSTORE_PASSWORD}"
    --keystore-entry-alias "${KEYSTORE_ALIAS}"
    --keystore-entry-password "${KEYSTORE_ENTRY_PASSWORD:-${KEYSTORE_PASSWORD}}"
  )
  SIGNING_STATUS="custom"
fi

# 3. Versiones de las herramientas (las escribe setup-tools.sh)
CLI_VERSION=""
PATCHES_VERSION=""
if [ -f tools/tools-info.json ]; then
  CLI_VERSION=$(jq -r '.cli_version // ""' tools/tools-info.json)
  PATCHES_VERSION=$(jq -r '.patches_version // ""' tools/tools-info.json)
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

# El flag correcto del CLI es -f/--filter-package-name. Si la versión del CLI no
# lo soporta se cae a la lista completa; si sí lo soporta y devuelve vacío es que
# el bundle no declara ese paquete y conviene fallar en vez de aplicar todo.
if AVAILABLE_PATCHES=$(java -jar tools/cli.jar list-patches \
      --patches tools/patches.jar \
      --filter-package-name "$PACKAGE_NAME" 2>&1); then
  FILTER_OK="true"
else
  FILTER_OK="false"
  echo "Aviso: 'list-patches --filter-package-name' no está disponible en este CLI." >&2
  AVAILABLE_PATCHES=$(java -jar tools/cli.jar list-patches --patches tools/patches.jar)
fi

if [ -z "$AVAILABLE_PATCHES" ]; then
  echo "Error: el bundle de parches no expone parches para '$PACKAGE_NAME'." >&2
  exit 1
fi

if [ "$FILTER_OK" != "true" ]; then
  echo "Aviso: se inspecciona la lista completa de parches (sin filtro por paquete)."
fi

echo "$AVAILABLE_PATCHES"

has_patch() {
  printf '%s' "$AVAILABLE_PATCHES" | grep -qiF "$1"
}

# 5. Lista de parches habilitados
BASE_PATCH_ARGS=()
BASE_ENABLED_NAMES=()

if has_patch "Brave Origin"; then
  BASE_PATCH_ARGS+=(-e "Brave Origin")
  BASE_ENABLED_NAMES+=("Brave Origin")
fi

if has_patch "Brave Startup Performance Optimization"; then
  BASE_PATCH_ARGS+=(-e "Brave Startup Performance Optimization")
  BASE_ENABLED_NAMES+=("Brave Startup Performance Optimization")
fi

WALLPAPER_FILE="assets/wallpaper.png"
if has_patch "Custom NTP wallpaper"; then
  if [ -f "$WALLPAPER_FILE" ]; then
    BASE_PATCH_ARGS+=(-e "Custom NTP wallpaper" -O customWallpaper="$WALLPAPER_FILE")
    BASE_ENABLED_NAMES+=("Custom NTP wallpaper")
  else
    echo "::warning::No existe '$WALLPAPER_FILE'; se omite el parche 'Custom NTP wallpaper'."
  fi
fi

if has_patch "Brave NTP four-column tiles"; then
  BASE_PATCH_ARGS+=(-e "Brave NTP four-column tiles")
  BASE_ENABLED_NAMES+=("Brave NTP four-column tiles")
fi

if [ ${#BASE_ENABLED_NAMES[@]} -eq 0 ]; then
  echo "Error: ninguno de los parches esperados está disponible en el bundle." >&2
  exit 1
fi

echo "Parches habilitados: ${BASE_ENABLED_NAMES[*]}"

# Función de ejecución de parcheo. El result-file es la fuente de verdad sobre
# qué parches se aplicaron realmente (los incompatibles se omiten en silencio).
patch_apk() {
  local target_apk="$1"
  local result_file="$2"
  shift 2
  local extra_args=("$@")

  echo "=========================================================="
  echo "==> Compilando: $target_apk"
  echo "=========================================================="

  java -jar tools/cli.jar patch \
    --patches tools/patches.jar \
    "${BASE_PATCH_ARGS[@]}" \
    ${extra_args[@]+"${extra_args[@]}"} \
    ${KEYSTORE_ARGS[@]+"${KEYSTORE_ARGS[@]}"} \
    --result-file "$result_file" \
    -o "$target_apk" \
    input.apk

  if ! jq -e '.success == true' "$result_file" > /dev/null 2>&1; then
    echo "Error: Morphe reportó un fallo al generar '$target_apk'." >&2
    jq . "$result_file" >&2 || true
    exit 1
  fi

  ls -lh "$target_apk"
}

# Devuelve el JSON de parches realmente aplicados según el result-file.
applied_patches_json() {
  local result_file="$1"
  jq -c '(.appliedPatches // []) | unique' "$result_file"
}

# Compara los parches habilitados con los aplicados. Omite avisos cuando la
# diferencia es un parche deshabilitado por incompatibilidad, pero falla si no
# se aplicó absolutamente nada o si el tema pedido no se pudo aplicar.
check_applied() {
  local result_file="$1"
  local theme="$2"
  local applied_json="$3"

  local applied_count
  applied_count=$(printf '%s' "$applied_json" | jq 'length')
  if [ "$applied_count" -eq 0 ]; then
    echo "Error: no se aplicó ningún parche. Revisa el bundle y la versión de Brave." >&2
    jq . "$result_file" >&2 || true
    exit 1
  fi

  local name
  for name in "${EXPECTED_NAMES[@]}"; do
    if ! printf '%s' "$applied_json" | jq -e --arg n "$name" 'index($n) != null' > /dev/null; then
      echo "::warning::El parche '$name' no se aplicó (probablemente incompatible con Brave $RESOLVED_BRAVE_VERSION)."
      MISSING_PATCHES+=("$name")
    fi
  done

  if [ "$theme" = "amoled" ]; then
    if ! printf '%s' "$applied_json" | jq -e --arg n "Brave AMOLED theme" 'index($n) != null' > /dev/null; then
      echo "Error: se pidió la variante AMOLED pero 'Brave AMOLED theme' no se aplicó." >&2
      exit 1
    fi
  fi
}

MISSING_PATCHES=()
GENERATED_APKS_JSON=()

# 6. Compilar Estándar si corresponde
if [ "$THEME_MODE" = "all" ] || [ "$THEME_MODE" = "standard" ]; then
  STD_APK="brave-${BRAVE_VARIANT}-${ARCH}-patched.apk"
  echo "==> Procesando variante Estándar..."

  EXPECTED_NAMES=("${BASE_ENABLED_NAMES[@]}")
  patch_apk "$STD_APK" "result-standard.json"

  STD_APPLIED=$(applied_patches_json "result-standard.json")
  check_applied "result-standard.json" "standard" "$STD_APPLIED"

  STD_HASH=$(sha256sum "$STD_APK" | awk '{print $1}')
  echo "${STD_HASH}  ${STD_APK}" > "${STD_APK}.sha256"

  STD_ENTRY=$(jq -cn \
    --arg file "$STD_APK" \
    --arg theme "standard" \
    --arg sha "$STD_HASH" \
    --argjson patches "$STD_APPLIED" \
    '{filename: $file, theme: $theme, sha256: $sha, applied_patches: $patches}')
  GENERATED_APKS_JSON+=("$STD_ENTRY")
fi

# 7. Compilar AMOLED si corresponde
if [ "$THEME_MODE" = "all" ] || [ "$THEME_MODE" = "amoled" ]; then
  AMOLED_APK="brave-${BRAVE_VARIANT}-${ARCH}-amoled-patched.apk"
  echo "==> Procesando variante AMOLED..."

  AMOLED_EXTRA=()
  EXPECTED_NAMES=("${BASE_ENABLED_NAMES[@]}")

  if has_patch "Brave AMOLED theme"; then
    AMOLED_EXTRA+=(-e "Brave AMOLED theme" -O backgroundColor="#000000")
    EXPECTED_NAMES+=("Brave AMOLED theme")
  else
    echo "Error: 'Brave AMOLED theme' no está disponible en este bundle; no se puede generar la variante AMOLED." >&2
    exit 1
  fi

  patch_apk "$AMOLED_APK" "result-amoled.json" "${AMOLED_EXTRA[@]}"

  AMOLED_APPLIED=$(applied_patches_json "result-amoled.json")
  check_applied "result-amoled.json" "amoled" "$AMOLED_APPLIED"

  AMOLED_HASH=$(sha256sum "$AMOLED_APK" | awk '{print $1}')
  echo "${AMOLED_HASH}  ${AMOLED_APK}" > "${AMOLED_APK}.sha256"

  AMOLED_ENTRY=$(jq -cn \
    --arg file "$AMOLED_APK" \
    --arg theme "amoled" \
    --arg sha "$AMOLED_HASH" \
    --argjson patches "$AMOLED_APPLIED" \
    '{filename: $file, theme: $theme, sha256: $sha, applied_patches: $patches}')
  GENERATED_APKS_JSON+=("$AMOLED_ENTRY")
fi

# 8. Guardar metadata estructurada en JSON
ALL_APKS_JSON=$(printf '%s\n' "${GENERATED_APKS_JSON[@]}" | jq -cs '.')

MISSING_JSON=$(printf '%s\n' "${MISSING_PATCHES[@]}" | jq -Rc 'select(length > 0)' | jq -cs 'unique // []')

METADATA_FILE="metadata-${BRAVE_VARIANT}-${ARCH}.json"
jq -cn \
  --arg variant "$BRAVE_VARIANT" \
  --arg arch "$ARCH" \
  --arg brave_version "$RESOLVED_BRAVE_VERSION" \
  --arg signing_status "$SIGNING_STATUS" \
  --arg cli_version "$CLI_VERSION" \
  --arg patches_version "$PATCHES_VERSION" \
  --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --argjson apks "$ALL_APKS_JSON" \
  --argjson missing "$MISSING_JSON" \
  '{
    variant: $variant,
    architecture: $arch,
    brave_version: $brave_version,
    signing_status: $signing_status,
    cli_version: $cli_version,
    patches_version: $patches_version,
    timestamp: $timestamp,
    apks: $apks,
    missing_patches: $missing
  }' > "$METADATA_FILE"

echo "=========================================================="
echo "==> Metadatos guardados en $METADATA_FILE:"
jq . "$METADATA_FILE"
echo "=========================================================="
