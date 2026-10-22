#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# resolve-matrix.sh
# Determina versiones upstream, decide si hay algo que compilar y construye la
# matriz de jobs. Los resultados se escriben en $GITHUB_OUTPUT.
# ==============================================================================

EVENT_NAME="${EVENT_NAME:-workflow_dispatch}"
INPUT_VARIANT="${INPUT_VARIANT:-all}"
INPUT_ARCH="${INPUT_ARCH:-all}"
INPUT_THEME="${INPUT_THEME:-all}"
INPUT_APK_URL="${INPUT_APK_URL:-}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

section() {
  echo "=========================================================="
  echo "==> $1"
  echo "=========================================================="
}

sanitize() {
  printf '%s' "$1" | tr -d ' ' | tr '/' '-'
}

# Los valores multilínea (o con caracteres especiales) deben escribirse con el
# formato heredoc de $GITHUB_OUTPUT; si no, el runner falla con
# "Invalid format" y aborta el job.
write_output() {
  local key="$1"
  local value="$2"
  {
    echo "${key}<<__OUTPUT_EOF__"
    printf '%s\n' "$value"
    echo "__OUTPUT_EOF__"
  } >> "$GITHUB_OUTPUT"
}

# ------------------------------------------------------------------------------
# 1. Parches dh6k/morphe-patches
# ------------------------------------------------------------------------------
section "1. Resolviendo dh6k/morphe-patches..."

LATEST_PATCHES_TAG=$(gh api "repos/dh6k/morphe-patches/releases?per_page=20" | jq -r '
  map(select(.assets | any(.name | endswith(".mpp") or endswith(".jar")))) | first | .tag_name // empty
' 2>/dev/null || true)

if [ -z "$LATEST_PATCHES_TAG" ]; then
  LATEST_PATCHES_TAG=$(gh api "repos/dh6k/morphe-patches/releases/latest" --jq '.tag_name // empty' 2>/dev/null || true)
fi

if [ -z "$LATEST_PATCHES_TAG" ] || [ "$LATEST_PATCHES_TAG" = "null" ]; then
  echo "Error: no se pudo resolver una versión válida de dh6k/morphe-patches." >&2
  exit 1
fi

echo "Versión de parches: '$LATEST_PATCHES_TAG'"

# ------------------------------------------------------------------------------
# 2. Versiones de Brave Browser
# ------------------------------------------------------------------------------
section "2. Resolviendo versiones de Brave Browser..."

# per_page=100 para que Beta/Nightly no salgan de la ventana de resultados
# (Brave publica Nightly con mucha frecuencia).
BRAVE_RELEASES_RAW=$(gh api "repos/brave/brave-browser/releases?per_page=100")

resolve_brave_tag() {
  local prefix="$1"
  local tag
  tag=$(printf '%s' "$BRAVE_RELEASES_RAW" | jq -r --arg prefix "$prefix" '
    map(select((.name | startswith($prefix)) and (.assets | any(.name | endswith(".apk"))))) | first | .tag_name // empty
  ')
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    printf ''
  else
    printf '%s' "$tag"
  fi
}

BRAVE_STABLE_TAG=$(resolve_brave_tag "Release ")
BRAVE_BETA_TAG=$(resolve_brave_tag "Beta ")
BRAVE_NIGHTLY_TAG=$(resolve_brave_tag "Nightly ")

echo "Brave Stable:  ${BRAVE_STABLE_TAG:-'(no detectado)'}"
echo "Brave Beta:    ${BRAVE_BETA_TAG:-'(no detectado)'}"
echo "Brave Nightly: ${BRAVE_NIGHTLY_TAG:-'(no detectado)'}"

if [ -z "$BRAVE_STABLE_TAG" ]; then
  echo "Error: no se pudo resolver la versión Stable de Brave Browser." >&2
  exit 1
fi

# Si se pidió una variante concreta, debe existir. Nunca se sustituye por
# Stable, porque produciría un APK mal etiquetado.
case "$INPUT_VARIANT" in
  Beta)
    if [ -z "$BRAVE_BETA_TAG" ]; then
      echo "Error: se pidió la variante Beta pero no hay release de Brave Beta con APKs." >&2
      exit 1
    fi
    ;;
  Nightly)
    if [ -z "$BRAVE_NIGHTLY_TAG" ]; then
      echo "Error: se pidió la variante Nightly pero no hay release de Brave Nightly con APKs." >&2
      exit 1
    fi
    ;;
esac

SAFE_PATCHES_TAG=$(sanitize "$LATEST_PATCHES_TAG")
SAFE_STABLE_TAG=$(sanitize "$BRAVE_STABLE_TAG")

# ------------------------------------------------------------------------------
# 3. Tag y título de la release
# ------------------------------------------------------------------------------
section "3. Resolviendo tag de release..."

PRERELEASE="false"
VARIANT_LABEL=""
TITLE_VARIANT="Brave Browser"

case "$INPUT_VARIANT" in
  Beta)
    TAG_CORE=$(sanitize "$BRAVE_BETA_TAG")
    VARIANT_LABEL="-Beta"
    TITLE_VARIANT="Brave Beta"
    PRERELEASE="true"
    ;;
  Nightly)
    TAG_CORE=$(sanitize "$BRAVE_NIGHTLY_TAG")
    VARIANT_LABEL="-Nightly"
    TITLE_VARIANT="Brave Nightly"
    PRERELEASE="true"
    ;;
  *)
    TAG_CORE="$SAFE_STABLE_TAG"
    ;;
esac

if [ -n "$INPUT_APK_URL" ]; then
  RELEASE_TAG="brave-custom-$(date +'%Y%m%d%H%M%S')"
  RELEASE_TITLE="Brave Patched (Custom APK - $(date +'%Y-%m-%d'))"
  PRERELEASE="false"
else
  # Un build parcial (arquitectura o tema concretos) usa un tag propio para no
  # sobrescribir las notas ni los checksums de la release completa.
  SCOPE_LABEL=""
  if [ "$INPUT_ARCH" != "all" ] || [ "$INPUT_THEME" != "all" ]; then
    SCOPE_LABEL="-${INPUT_ARCH}-${INPUT_THEME}"
  fi

  RELEASE_TITLE="${TITLE_VARIANT} ${TAG_CORE} (${LATEST_PATCHES_TAG})"
  if [ -n "$SCOPE_LABEL" ]; then
    RELEASE_TITLE="${RELEASE_TITLE} [build parcial: ${INPUT_ARCH} - ${INPUT_THEME}]"
  fi

  RELEASE_TAG="brave${VARIANT_LABEL}-${TAG_CORE}-${SAFE_PATCHES_TAG}${SCOPE_LABEL}"
fi

echo "Tag:    $RELEASE_TAG"
echo "Título: $RELEASE_TITLE"

# ------------------------------------------------------------------------------
# 4. ¿Hay algo nuevo que compilar? (solo cron)
# ------------------------------------------------------------------------------
if [ "$EVENT_NAME" = "schedule" ] && [ -n "$RELEASE_TAG" ]; then
  section "4. Verificando si la release ya está al día..."

  if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
    RELEASE_BODY=$(gh release view "$RELEASE_TAG" --json body --jq '.body // ""')
    STALE="false"

    # Las notas incluyen la versión efectiva de cada variante y la de parches.
    # Se comparan con grep -F para evitar falsos positivos por regex.
    for pair in "Stable:${BRAVE_STABLE_TAG}" "Beta:${BRAVE_BETA_TAG}" "Nightly:${BRAVE_NIGHTLY_TAG}"; do
      label="${pair%%:*}"
      current="${pair#*:}"
      [ -n "$current" ] || continue
      if ! printf '%s' "$RELEASE_BODY" | grep -Fq "$current"; then
        echo "Nueva versión de Brave ${label}: $current"
        STALE="true"
      fi
    done

    if ! printf '%s' "$RELEASE_BODY" | grep -Fq "$LATEST_PATCHES_TAG"; then
      echo "Nueva versión de parches: $LATEST_PATCHES_TAG"
      STALE="true"
    fi

    if [ "$STALE" = "false" ]; then
      echo "==> La release '$RELEASE_TAG' ya contiene todas las versiones actuales."
      echo "==> No hay nada que compilar."
      write_output "should_run" "false"
      write_output "matrix" '{"include":[]}'
      exit 0
    fi
  fi
fi

# ------------------------------------------------------------------------------
# 5. Matriz de compilación
# ------------------------------------------------------------------------------
section "5. Construyendo matriz de compilación..."

VARIANTS=()
case "$INPUT_VARIANT" in
  all|"")
    if [ -n "$INPUT_APK_URL" ]; then
      # Un APK manual no permite distinguir la variante: se asume Stable.
      VARIANTS=("Stable")
    else
      for v in Stable Beta Nightly; do
        case "$v" in
          Stable) current="$BRAVE_STABLE_TAG" ;;
          Beta) current="$BRAVE_BETA_TAG" ;;
          Nightly) current="$BRAVE_NIGHTLY_TAG" ;;
        esac
        if [ -n "$current" ]; then
          VARIANTS+=("$v")
        else
          echo "Aviso: Brave $v no tiene release con APKs; se omite." >&2
        fi
      done
    fi
    ;;
  *)
    VARIANTS=("$INPUT_VARIANT")
    ;;
esac

if [ ${#VARIANTS[@]} -eq 0 ]; then
  echo "Error: no hay ninguna variante de Brave disponible para compilar." >&2
  exit 1
fi

ARCHS=()
if [ -n "$INPUT_APK_URL" ]; then
  # Un APK manual es un único archivo: no tiene sentido generar legs por ABI.
  ARCHS=("custom")
else
  case "$INPUT_ARCH" in
    all|"") ARCHS=("armv8" "armv7" "universal") ;;
    *) ARCHS=("$INPUT_ARCH") ;;
  esac
fi

case "$INPUT_THEME" in
  standard|amoled) THEME_MODE="$INPUT_THEME" ;;
  *) THEME_MODE="all" ;;
esac

MATRIX_INCLUDES=()
for v in "${VARIANTS[@]}"; do
  case "$v" in
    Stable) BTAG="$BRAVE_STABLE_TAG" ;;
    Beta) BTAG="$BRAVE_BETA_TAG" ;;
    Nightly) BTAG="$BRAVE_NIGHTLY_TAG" ;;
    *) BTAG="$BRAVE_STABLE_TAG" ;;
  esac

  [ -n "$BTAG" ] || continue

  for a in "${ARCHS[@]}"; do
    # jq construye cada entrada para escapar correctamente valores arbitrarios
    # (por ejemplo una URL con comillas).
    MATRIX_INCLUDES+=("$(
      jq -cn \
        --arg variant "$v" \
        --arg arch "$a" \
        --arg theme "$THEME_MODE" \
        --arg tag "$BTAG" \
        --arg url "$INPUT_APK_URL" \
        '{brave_variant: $variant, architecture: $arch, theme_mode: $theme, brave_tag: $tag, apk_url: $url}'
    )")
  done
done

if [ ${#MATRIX_INCLUDES[@]} -eq 0 ]; then
  echo "Error: la matriz quedó vacía." >&2
  exit 1
fi

# -c es obligatorio: $GITHUB_OUTPUT no admite valores multilínea.
MATRIX_JSON=$(printf '%s\n' "${MATRIX_INCLUDES[@]}" | jq -cs '{include: .}')

echo "Matriz generada (${#MATRIX_INCLUDES[@]} legs):"
printf '%s' "$MATRIX_JSON" | jq .

write_output "should_run" "true"
write_output "matrix" "$MATRIX_JSON"
write_output "release_tag" "$RELEASE_TAG"
write_output "release_title" "$RELEASE_TITLE"
write_output "prerelease" "$PRERELEASE"
write_output "patches_version" "$LATEST_PATCHES_TAG"
