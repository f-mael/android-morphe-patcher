#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# resolve-matrix.sh
# Determina versiones upstream, verifica si ya existe release, y construye la matriz.
# ==============================================================================

EVENT_NAME="${EVENT_NAME:-workflow_dispatch}"
INPUT_VARIANT="${INPUT_VARIANT:-all}"
INPUT_ARCH="${INPUT_ARCH:-all}"
INPUT_THEME="${INPUT_THEME:-all}"
INPUT_APK_URL="${INPUT_APK_URL:-}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

echo "=========================================================="
echo "==> 1. Resolviendo versión de dh6k/morphe-patches..."
echo "=========================================================="
# Buscar la última release (incluyendo pre-releases) que contenga activos .mpp o .jar
LATEST_PATCHES_TAG=$(gh api "repos/dh6k/morphe-patches/releases?per_page=10" | jq -r '
  map(select(.assets | any(.name | endswith(".mpp") or endswith(".jar")))) | first | .tag_name // empty
' 2>/dev/null || true)

if [ -z "$LATEST_PATCHES_TAG" ] || [ "$LATEST_PATCHES_TAG" = "null" ]; then
  LATEST_PATCHES_TAG=$(gh api "repos/dh6k/morphe-patches/releases/latest" --jq '.tag_name // empty' 2>/dev/null || true)
fi

if [ -z "$LATEST_PATCHES_TAG" ] || [ "$LATEST_PATCHES_TAG" = "null" ]; then
  echo "Error: No se pudo resolver una versión válida de dh6k/morphe-patches." >&2
  exit 1
fi
echo "Versión de parches: '$LATEST_PATCHES_TAG'"

echo "=========================================================="
echo "==> 2. Resolviendo versiones de Brave Browser..."
echo "=========================================================="
BRAVE_RELEASES_RAW=$(gh api "repos/brave/brave-browser/releases?per_page=30")

resolve_brave_tag() {
  local prefix="$1"
  local tag
  tag=$(echo "$BRAVE_RELEASES_RAW" | jq -r --arg prefix "$prefix" '
    map(select((.name | startswith($prefix)) and (.assets | any(.name | endswith(".apk"))))) | first | .tag_name // empty
  ')
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    echo ""
  else
    echo "$tag"
  fi
}

BRAVE_STABLE_TAG=$(resolve_brave_tag "Release ")
BRAVE_BETA_TAG=$(resolve_brave_tag "Beta ")
BRAVE_NIGHTLY_TAG=$(resolve_brave_tag "Nightly ")

echo "Brave Stable:  ${BRAVE_STABLE_TAG:-'(no detectado)'}"
echo "Brave Beta:    ${BRAVE_BETA_TAG:-'(no detectado)'}"
echo "Brave Nightly: ${BRAVE_NIGHTLY_TAG:-'(no detectado)'}"

if [ -z "$BRAVE_STABLE_TAG" ]; then
  echo "Error: No se pudo resolver la versión Stable de Brave Browser." >&2
  exit 1
fi

SAFE_STABLE_TAG=$(echo "$BRAVE_STABLE_TAG" | tr -d ' ' | tr '/' '-')
SAFE_PATCHES_TAG=$(echo "$LATEST_PATCHES_TAG" | tr -d ' ' | tr '/' '-')

# Configuración de tag y título de release
PRERELEASE="false"
if [ -n "$INPUT_APK_URL" ]; then
  RELEASE_TAG="brave-custom-$(date +'%Y%m%d%H%M%S')"
  RELEASE_TITLE="Brave Patched (Custom APK - $(date +'%Y-%m-%d'))"
elif [ "$INPUT_VARIANT" = "Beta" ]; then
  SAFE_TAG=$(echo "${BRAVE_BETA_TAG:-$BRAVE_STABLE_TAG}" | tr -d ' ' | tr '/' '-')
  RELEASE_TAG="brave-Beta-${SAFE_TAG}-${SAFE_PATCHES_TAG}"
  RELEASE_TITLE="Brave Beta ${BRAVE_BETA_TAG:-$BRAVE_STABLE_TAG} (${LATEST_PATCHES_TAG})"
  PRERELEASE="true"
elif [ "$INPUT_VARIANT" = "Nightly" ]; then
  SAFE_TAG=$(echo "${BRAVE_NIGHTLY_TAG:-$BRAVE_STABLE_TAG}" | tr -d ' ' | tr '/' '-')
  RELEASE_TAG="brave-Nightly-${SAFE_TAG}-${SAFE_PATCHES_TAG}"
  RELEASE_TITLE="Brave Nightly ${BRAVE_NIGHTLY_TAG:-$BRAVE_STABLE_TAG} (${LATEST_PATCHES_TAG})"
  PRERELEASE="true"
else
  RELEASE_TAG="brave-${SAFE_STABLE_TAG}-${SAFE_PATCHES_TAG}"
  RELEASE_TITLE="Brave Browser ${BRAVE_STABLE_TAG} (${LATEST_PATCHES_TAG})"
fi

# Comprobación de cambios en ejecución programada (cron)
if [ "$EVENT_NAME" = "schedule" ]; then
  echo "=========================================================="
  echo "==> Verificando si ya existe release para: $RELEASE_TAG"
  echo "=========================================================="
  if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
    RELEASE_BODY=$(gh release view "$RELEASE_TAG" --json body --jq '.body // ""' 2>/dev/null || echo "")
    BETA_OK="true"
    NIGHTLY_OK="true"

    if [ -n "$BRAVE_BETA_TAG" ] && ! echo "$RELEASE_BODY" | grep -q "$BRAVE_BETA_TAG"; then
      echo "Nueva versión detectada para Brave Beta: $BRAVE_BETA_TAG"
      BETA_OK="false"
    fi

    if [ -n "$BRAVE_NIGHTLY_TAG" ] && ! echo "$RELEASE_BODY" | grep -q "$BRAVE_NIGHTLY_TAG"; then
      echo "Nueva versión detectada para Brave Nightly: $BRAVE_NIGHTLY_TAG"
      NIGHTLY_OK="false"
    fi

    if [ "$BETA_OK" = "true" ] && [ "$NIGHTLY_OK" = "true" ]; then
      echo "==> Todas las variantes (Stable, Beta, Nightly) y parches están al día en $RELEASE_TAG."
      echo "==> Finalizando ejecución limpiamente."
      echo "should_run=false" >> "$GITHUB_OUTPUT"
      echo "matrix={\"include\":[]}" >> "$GITHUB_OUTPUT"
      exit 0
    fi
  fi
fi

# Construir la matriz de compilación
# Nota: La matriz se paraleliza por (variante, arquitectura). Los temas (estándar y amoled)
# se procesan en la misma leg para reutilizar la descarga de input.apk.
VARIANTS=()
if [ -n "$INPUT_APK_URL" ]; then
  case "$INPUT_VARIANT" in
    all|"") VARIANTS=("Stable") ;;
    *) VARIANTS=("$INPUT_VARIANT") ;;
  esac
else
  case "$INPUT_VARIANT" in
    all|"") VARIANTS=("Stable" "Beta" "Nightly") ;;
    *) VARIANTS=("$INPUT_VARIANT") ;;
  esac
fi

ARCHS=()
case "$INPUT_ARCH" in
  all|"") ARCHS=("armv8" "armv7" "universal") ;;
  *) ARCHS=("$INPUT_ARCH") ;;
esac

THEME_MODE="$INPUT_THEME"
case "$THEME_MODE" in
  standard|amoled|all) ;;
  *) THEME_MODE="all" ;;
esac

MATRIX_INCLUDES=()
for v in "${VARIANTS[@]}"; do
  # Asignar el tag exacto de Brave según la variante para evitar discrepancias
  case "$v" in
    Stable) BTAG="$BRAVE_STABLE_TAG" ;;
    Beta) BTAG="${BRAVE_BETA_TAG:-$BRAVE_STABLE_TAG}" ;;
    Nightly) BTAG="${BRAVE_NIGHTLY_TAG:-$BRAVE_STABLE_TAG}" ;;
    *) BTAG="$BRAVE_STABLE_TAG" ;;
  esac

  for a in "${ARCHS[@]}"; do
    MATRIX_INCLUDES+=(
      "{\"brave_variant\": \"$v\", \"architecture\": \"$a\", \"theme_mode\": \"$THEME_MODE\", \"brave_tag\": \"$BTAG\", \"apk_url\": \"$INPUT_APK_URL\"}"
    )
  done
done

MATRIX_JSON=$(printf '%s\n' "${MATRIX_INCLUDES[@]}" | jq -s '{"include": .}')

echo "=========================================================="
echo "==> Matriz generada (${#MATRIX_INCLUDES[@]} legs):"
echo "$MATRIX_JSON" | jq .
echo "=========================================================="

echo "should_run=true" >> "$GITHUB_OUTPUT"
echo "matrix=$MATRIX_JSON" >> "$GITHUB_OUTPUT"
echo "release_tag=$RELEASE_TAG" >> "$GITHUB_OUTPUT"
echo "release_title=$RELEASE_TITLE" >> "$GITHUB_OUTPUT"
echo "prerelease=$PRERELEASE" >> "$GITHUB_OUTPUT"
echo "patches_version=$LATEST_PATCHES_TAG" >> "$GITHUB_OUTPUT"
echo "brave_stable_version=$BRAVE_STABLE_TAG" >> "$GITHUB_OUTPUT"
echo "brave_beta_version=${BRAVE_BETA_TAG:-N/A}" >> "$GITHUB_OUTPUT"
echo "brave_nightly_version=${BRAVE_NIGHTLY_TAG:-N/A}" >> "$GITHUB_OUTPUT"
