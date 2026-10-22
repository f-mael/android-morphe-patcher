#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# publish-release.sh
# Consolida los metadatos JSON de todas las legs, genera las notas de release y
# publica o actualiza la release en GitHub Releases.
#
# Uso: publish-release.sh <assets_dir> <tag> <title> <patches_version> \
#                         <prerelease> <patch_result>
# ==============================================================================

ASSETS_DIR="${1:-release-assets}"
RELEASE_TAG="${2:-}"
RELEASE_TITLE="${3:-}"
PATCHES_VERSION="${4:-}"
PRERELEASE="${5:-false}"
PATCH_RESULT="${6:-success}"

if [ -z "$RELEASE_TAG" ] || [ -z "$RELEASE_TITLE" ]; then
  echo "Error: se requieren RELEASE_TAG y RELEASE_TITLE." >&2
  exit 1
fi

echo "=========================================================="
echo "==> Consolidando activos en: $ASSETS_DIR"
echo "    Tag:          $RELEASE_TAG"
echo "    Título:       $RELEASE_TITLE"
echo "    Resultado CI: $PATCH_RESULT"
echo "=========================================================="

# ------------------------------------------------------------------------------
# 1. Validaciones
# ------------------------------------------------------------------------------
if ! compgen -G "${ASSETS_DIR}/*.apk" > /dev/null; then
  echo "Error: no se encontró ningún archivo APK en ${ASSETS_DIR}." >&2
  exit 1
fi

if ! compgen -G "${ASSETS_DIR}/metadata-*.json" > /dev/null; then
  echo "Error: no se encontró ningún archivo de metadatos en ${ASSETS_DIR}." >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 2. Consolidar checksums
# ------------------------------------------------------------------------------
sort "${ASSETS_DIR}"/*.sha256 > "${ASSETS_DIR}/checksums.txt"

# ------------------------------------------------------------------------------
# 3. Consolidar metadatos
# ------------------------------------------------------------------------------
ALL_METAS=$(jq -s '.' "${ASSETS_DIR}"/metadata-*.json)

TOTAL_LEGS=$(printf '%s' "$ALL_METAS" | jq 'length')
CUSTOM_LEGS=$(printf '%s' "$ALL_METAS" | jq '[.[] | select(.signing_status == "custom")] | length')

if [ "$CUSTOM_LEGS" -eq 0 ]; then
  SIGNING_INFO="Firmado con keystore de depuración (Morphe CLI predeterminado)"
elif [ "$CUSTOM_LEGS" -eq "$TOTAL_LEGS" ]; then
  SIGNING_INFO="Firmado con keystore personalizado (persistente)"
else
  SIGNING_INFO="⚠️ Firma mixta: ${CUSTOM_LEGS}/${TOTAL_LEGS} legs con keystore personalizado"
fi

CLI_VERSION=$(printf '%s' "$ALL_METAS" | jq -r '[.[].cli_version // empty] | unique | join(", ")')
[ -n "$CLI_VERSION" ] || CLI_VERSION="desconocida"

# La versión real del bundle la registra setup-tools.sh en los metadatos; tiene
# prioridad sobre el valor resuelto en el job `check`.
META_PATCHES_VERSION=$(printf '%s' "$ALL_METAS" | jq -r '[.[].patches_version // empty] | unique | join(", ")')
if [ -n "$META_PATCHES_VERSION" ]; then
  PATCHES_VERSION="$META_PATCHES_VERSION"
fi

BUILD_DATE=$(date -u +'%Y-%m-%d %H:%M:%S UTC')

# Parches realmente aplicados en todos los APKs publicados
APPLIED_MD=$(printf '%s' "$ALL_METAS" | jq -r '[.[].apks[].applied_patches[]?] | unique | .[] | "- **\(.)**"')
MISSING_MD=$(printf '%s' "$ALL_METAS" | jq -r '[.[].missing_patches[]?] | unique | .[] | "> - **\(.)**"')

# ------------------------------------------------------------------------------
# 4. Generar release_notes.md
# ------------------------------------------------------------------------------
{
  echo "# Brave Browser Android (Morphe Patched)"
  echo ""
  echo "Compilaciones automatizadas de Brave Browser para Android con parches de [dh6k/morphe-patches](https://github.com/dh6k/morphe-patches)."
  echo ""

  if [ "$PATCH_RESULT" = "failure" ]; then
    echo "> [!WARNING]"
    echo "> Algunas compilaciones fallaron durante la ejecución de la matriz. Se publican solo los binarios que terminaron correctamente."
    echo ""
  fi

  if [ -n "$MISSING_MD" ]; then
    echo "> [!NOTE]"
    echo "> Los siguientes parches no pudieron aplicarse en algunas variantes (incompatibilidad con la versión de Brave):"
    printf '%s\n' "$MISSING_MD"
    echo ">"
    echo "> El detalle por APK está en \`metadata-*.json\`; no se publica como asset, pero queda en el log del workflow."
    echo ""
  fi

  echo "## Información de la versión"
  echo ""
  echo "| Parámetro | Valor |"
  echo "| :--- | :--- |"
  echo "| **Versión dh6k/morphe-patches** | \`${PATCHES_VERSION}\` |"
  echo "| **Versión Morphe CLI** | \`${CLI_VERSION}\` |"
  echo "| **Estado de firma** | ${SIGNING_INFO} |"
  echo "| **Fecha de compilación** | \`${BUILD_DATE}\` |"
  echo ""
  echo "## Paquetes APK disponibles"
  echo ""
  echo "| Variante | Arquitectura | Tema | Versión Base | Archivo APK |"
  echo "| :--- | :--- | :--- | :--- | :--- |"

  printf '%s' "$ALL_METAS" | jq -r '
    def vorder: if .variant == "Stable" then 0 elif .variant == "Beta" then 1 elif .variant == "Nightly" then 2 else 3 end;
    def aorder: if .architecture == "armv8" then 0 elif .architecture == "armv7" then 1 elif .architecture == "universal" then 2 else 3 end;
    def torder: if .theme == "standard" then 0 else 1 end;

    [ .[] as $group | $group.apks[] | {group: $group, apk: .} ]
    | sort_by([(.group | vorder), (.group | aorder), (.apk | torder)])
    | .[]
    | (if .apk.theme == "amoled" then "🖤 AMOLED" else "Estándar" end) as $theme_label
    | "| **\(.group.variant)** | `\(.group.architecture)` | \($theme_label) | `\(.group.brave_version)` | `\(.apk.filename)` |"
  '

  echo ""
  echo "## Parches aplicados"
  echo ""
  if [ -n "$APPLIED_MD" ]; then
    printf '%s\n' "$APPLIED_MD"
  else
    echo "_No se registraron parches aplicados._"
  fi

  echo ""
  echo "## Verificación de integridad (SHA-256)"
  echo ""
  echo '```text'
  cat "${ASSETS_DIR}/checksums.txt"
  echo '```'
} > release_notes.md

echo "=========================================================="
echo "Release notes generadas:"
echo "=========================================================="
cat release_notes.md

# ------------------------------------------------------------------------------
# 5. Publicar o actualizar en GitHub Releases
# ------------------------------------------------------------------------------
PRERELEASE_FLAG=""
if [ "$PRERELEASE" = "true" ]; then
  PRERELEASE_FLAG="--prerelease"
fi

FILES_TO_UPLOAD=( "${ASSETS_DIR}"/*.apk "${ASSETS_DIR}/checksums.txt" )

if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  echo "==> Actualizando release existente '$RELEASE_TAG'..."
  if ! gh release edit "$RELEASE_TAG" --title "$RELEASE_TITLE" --notes-file release_notes.md $PRERELEASE_FLAG; then
    echo "::warning::No se pudieron actualizar las notas de '$RELEASE_TAG'; se continúa con la subida de binarios."
  fi
  gh release upload "$RELEASE_TAG" "${FILES_TO_UPLOAD[@]}" --clobber
else
  echo "==> Creando nueva release '$RELEASE_TAG'..."
  gh release create "$RELEASE_TAG" "${FILES_TO_UPLOAD[@]}" \
    --title "$RELEASE_TITLE" \
    --notes-file release_notes.md \
    --target "${GITHUB_REF_NAME:-main}" \
    $PRERELEASE_FLAG
fi

echo "=========================================================="
echo "==> Publicación completada exitosamente."
echo "=========================================================="
