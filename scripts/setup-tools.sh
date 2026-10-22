#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# setup-tools.sh
# Descarga y prepara Morphe CLI y el bundle de parches.
#
# Uso: setup-tools.sh [patches_tag] [tools_dir]
# ==============================================================================

PATCHES_TAG="${1:-latest}"
TOOLS_DIR="${2:-tools}"

DOWNLOAD_DIR="${TOOLS_DIR}/.download"

section() {
  echo "=========================================================="
  echo "==> $1"
  echo "=========================================================="
}

reset_download_dir() {
  rm -rf "$DOWNLOAD_DIR"
  mkdir -p "$DOWNLOAD_DIR"
}

mkdir -p "$TOOLS_DIR"

# ------------------------------------------------------------------------------
# 1. Morphe CLI
# ------------------------------------------------------------------------------
section "1. Resolviendo y descargando Morphe CLI..."

# MorpheApp/morphe-cli redirige a morphe-desktop; se usa el repo final
# directamente para evitar una llamada extra.
CLI_TAG=$(gh api "repos/MorpheApp/morphe-desktop/releases/latest" --jq '.tag_name // empty' 2>/dev/null || true)

if [ -z "$CLI_TAG" ] || [ "$CLI_TAG" = "null" ]; then
  echo "Aviso: no se pudo resolver el tag del CLI; se usa la última release disponible." >&2
  CLI_TAG="latest"
fi

echo "Tag de Morphe CLI: $CLI_TAG"

reset_download_dir
if [ "$CLI_TAG" != "latest" ]; then
  gh release download "$CLI_TAG" --repo MorpheApp/morphe-desktop --pattern "*all.jar" --dir "$DOWNLOAD_DIR"
else
  gh release download --repo MorpheApp/morphe-desktop --pattern "*all.jar" --dir "$DOWNLOAD_DIR"
fi

CLI_JAR=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f -name '*all.jar' -print -quit)
if [ -z "$CLI_JAR" ]; then
  echo "Error: no se encontró el jar del Morphe CLI en la release '$CLI_TAG'." >&2
  exit 1
fi

mv "$CLI_JAR" "${TOOLS_DIR}/cli.jar"
echo "Morphe CLI listo: ${TOOLS_DIR}/cli.jar"

# ------------------------------------------------------------------------------
# 2. Bundle de parches
# ------------------------------------------------------------------------------
section "2. Descargando parches de dh6k/morphe-patches ($PATCHES_TAG)..."

# Descarga en un directorio aislado y mueve solo el archivo encontrado. Evita el
# clásico 'mv *.jar' que falla con múltiples orígenes (cli.jar + patches.jar).
download_patches() {
  local tag="$1"
  local pattern file
  local tag_args=()

  if [ -n "$tag" ] && [ "$tag" != "latest" ]; then
    tag_args=("$tag")
  fi

  for pattern in "*.mpp" "*.jar"; do
    reset_download_dir
    if gh release download ${tag_args[@]+"${tag_args[@]}"} \
        --repo dh6k/morphe-patches \
        --pattern "$pattern" \
        --dir "$DOWNLOAD_DIR" 2>/dev/null; then
      file=$(find "$DOWNLOAD_DIR" -maxdepth 1 -type f \( -name '*.mpp' -o -name '*.jar' \) -print -quit)
      if [ -n "$file" ]; then
        mv "$file" "${TOOLS_DIR}/patches.jar"
        echo "Bundle descargado ($(basename "$file"))."
        return 0
      fi
    fi
  done

  return 1
}

ACTUAL_PATCHES_TAG="$PATCHES_TAG"
if download_patches "$PATCHES_TAG"; then
  :
elif [ "$PATCHES_TAG" != "latest" ]; then
  echo "Aviso: no se pudo descargar con el tag '$PATCHES_TAG'; reintentando con la última release." >&2
  ACTUAL_PATCHES_TAG="latest"
  if ! download_patches "latest"; then
    echo "Error: no se pudo descargar el bundle de parches de dh6k/morphe-patches." >&2
    exit 1
  fi
else
  echo "Error: no se pudo descargar el bundle de parches de dh6k/morphe-patches." >&2
  exit 1
fi

rm -rf "$DOWNLOAD_DIR"

if ! java -jar "${TOOLS_DIR}/cli.jar" list-patches --patches "${TOOLS_DIR}/patches.jar" > /dev/null 2>&1; then
  echo "Error: el bundle de parches no se pudo cargar con el Morphe CLI." >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 3. Registrar versiones exactas
# ------------------------------------------------------------------------------
section "3. Herramientas preparadas"

jq -n \
  --arg cli_version "$CLI_TAG" \
  --arg patches_version "$ACTUAL_PATCHES_TAG" \
  --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '{
    cli_version: $cli_version,
    patches_version: $patches_version,
    timestamp: $timestamp
  }' > "${TOOLS_DIR}/tools-info.json"

ls -lh "$TOOLS_DIR"
jq . "${TOOLS_DIR}/tools-info.json"
