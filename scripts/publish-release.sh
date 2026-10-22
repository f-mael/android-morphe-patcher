#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# publish-release.sh
# Consolida metadatos JSON de todas las legs, genera las notas de release
# y publica o actualiza la release en GitHub Releases.
# ==============================================================================

ASSETS_DIR="${1:-release-assets}"
RELEASE_TAG="${2:-}"
RELEASE_TITLE="${3:-}"
PATCHES_VERSION="${4:-}"
PRERELEASE="${5:-false}"
PATCH_RESULT="${6:-success}"

if [ -z "$RELEASE_TAG" ] || [ -z "$RELEASE_TITLE" ]; then
  echo "Error: Se requieren RELEASE_TAG y RELEASE_TITLE." >&2
  exit 1
fi

echo "=========================================================="
echo "==> Consolidando activos en: $ASSETS_DIR"
echo "    Tag:          $RELEASE_TAG"
echo "    Título:       $RELEASE_TITLE"
echo "    Resultado CI: $PATCH_RESULT"
echo "=========================================================="

# Verificar existencia de APKs
if ! compgen -G "${ASSETS_DIR}/*.apk" > /dev/null; then
  echo "Error: No se encontró ningún archivo APK en ${ASSETS_DIR}." >&2
  exit 1
fi

# 1. Consolidar checksums
cat "${ASSETS_DIR}"/*.sha256 > "${ASSETS_DIR}/checksums.txt"

# 2. Consolidar metadatos JSON
ALL_METAS=$(jq -s '.' "${ASSETS_DIR}"/metadata-*.json 2>/dev/null || echo "[]")

# 3. Detectar estado de firma general
IS_CUSTOM=$(echo "$ALL_METAS" | jq -r '.[].signing_status' | grep -q "custom" && echo "true" || echo "false")
if [ "$IS_CUSTOM" = "true" ]; then
  SIGNING_INFO="Firmado con keystore personalizado (persistente)"
else
  SIGNING_INFO="Firmado con keystore de depuración (Morphe CLI predeterminado)"
fi

BUILD_DATE=$(date -u +'%Y-%m-%d %H:%M:%S UTC')

# 4. Generar release_notes.md
{
  echo "# Brave Browser Android (Morphe Patched)"
  echo ""
  echo "Compilaciones automatizadas de Brave Browser para Android con parches de [dh6k/morphe-patches](https://github.com/dh6k/morphe-patches)."
  echo ""

  if [ "$PATCH_RESULT" = "failure" ]; then
    echo "> [!WARNING]"
    echo "> Algunas compilaciones fallaron durante la ejecución de la matriz. Se publican los binarios que completaron el proceso exitosamente."
    echo ""
  fi

  echo "## Información de la versión"
  echo ""
  echo "| Parámetro | Valor |"
  echo "| :--- | :--- |"
  echo "| **Versión dh6k/morphe-patches** | \`${PATCHES_VERSION}\` |"
  echo "| **Estado de firma** | ${SIGNING_INFO} |"
  echo "| **Fecha de compilación** | \`${BUILD_DATE}\` |"
  echo ""
  echo "## Paquetes APK disponibles"
  echo ""
  echo "| Variante | Arquitectura | Tema | Versión Base | Archivo APK |"
  echo "| :--- | :--- | :--- | :--- | :--- |"

  echo "$ALL_METAS" | jq -r '
    .[] as $group |
    $group.apks[] |
    (if .theme == "amoled" then "🖤 AMOLED" else "Estándar" end) as $theme_label |
    "| **\($group.variant)** | `\($group.architecture)` | \($theme_label) | `\($group.brave_version)` | `\(.filename)` |"
  '

  echo ""
  echo "## Parches de Brave aplicados"
  echo ""
  echo "- **Brave Origin**: Desbloqueo de opciones y controles avanzados de funciones."
  echo "- **Brave Startup Performance Optimization**: Eliminación de comprobaciones y latencia OEM en el arranque."
  echo "- **Custom NTP wallpaper**: Fondo personalizado en la Nueva Pestaña (NTP)."
  echo "- **Brave NTP four-column tiles**: Mantiene las tarjetas en cuadrícula de 4 columnas descendente con fondo activado."
  echo "- **Brave AMOLED theme** *(variantes AMOLED)*: Superficies oscuras en negro puro OLED (\`#000000\`) y desactivación de Material You."
  echo ""
  echo "## Verificación de integridad (SHA-256)"
  echo ""
  echo '```text'
  cat "${ASSETS_DIR}/checksums.txt"
  echo '```'
} > release_notes.md

echo "=========================================================="
echo "Release Notes generadas:"
echo "=========================================================="
cat release_notes.md

# 5. Publicar o actualizar en GitHub Releases
PRERELEASE_FLAG=""
if [ "$PRERELEASE" = "true" ]; then
  PRERELEASE_FLAG="--prerelease"
fi

FILES_TO_UPLOAD=( "${ASSETS_DIR}"/*.apk "${ASSETS_DIR}/checksums.txt" )

if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  echo "==> Actualizando release existente '$RELEASE_TAG'..."
  gh release edit "$RELEASE_TAG" --title "$RELEASE_TITLE" --notes-file release_notes.md $PRERELEASE_FLAG || true
  gh release upload "$RELEASE_TAG" "${FILES_TO_UPLOAD[@]}" --clobber
else
  echo "==> Creando nueva release única '$RELEASE_TAG'..."
  gh release create "$RELEASE_TAG" "${FILES_TO_UPLOAD[@]}" \
    --title "$RELEASE_TITLE" \
    --notes-file release_notes.md \
    --target "${GITHUB_REF_NAME:-main}" \
    $PRERELEASE_FLAG
fi

echo "=========================================================="
echo "==> Publicación completada exitosamente."
echo "=========================================================="
