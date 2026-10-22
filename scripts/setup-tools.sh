#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# setup-tools.sh
# Descarga y prepara Morphe CLI, el bundle de parches e integraciones.
# ==============================================================================

PATCHES_TAG="${1:-latest}"
TOOLS_DIR="${2:-tools}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

mkdir -p "$TOOLS_DIR"

echo "=========================================================="
echo "==> 1. Resolviendo y descargando Morphe CLI..."
echo "=========================================================="
CLI_TAG=$(gh api "repos/MorpheApp/morphe-cli/releases/latest" --jq '.tag_name // empty' 2>/dev/null || true)
if [ -z "$CLI_TAG" ] || [ "$CLI_TAG" = "null" ]; then
  CLI_TAG=$(gh api "repos/MorpheApp/morphe-desktop/releases/latest" --jq '.tag_name // empty' 2>/dev/null || echo "latest")
fi

echo "Tag de Morphe CLI: $CLI_TAG"

if [ "$CLI_TAG" != "latest" ]; then
  gh release download "$CLI_TAG" --repo MorpheApp/morphe-cli --pattern "*all.jar" --dir "$TOOLS_DIR" 2>/dev/null || \
  gh release download "$CLI_TAG" --repo MorpheApp/morphe-desktop --pattern "*all.jar" --dir "$TOOLS_DIR" 2>/dev/null || \
  gh release download --repo MorpheApp/morphe-cli --pattern "*all.jar" --dir "$TOOLS_DIR"
else
  gh release download --repo MorpheApp/morphe-cli --pattern "*all.jar" --dir "$TOOLS_DIR" 2>/dev/null || \
  gh release download --repo MorpheApp/morphe-desktop --pattern "*all.jar" --dir "$TOOLS_DIR"
fi

mv "$TOOLS_DIR"/*all.jar "$TOOLS_DIR/cli.jar"
chmod +x "$TOOLS_DIR/cli.jar"

echo "=========================================================="
echo "==> 2. Descargando parches de dh6k/morphe-patches ($PATCHES_TAG)..."
echo "=========================================================="
DOWNLOADED="false"

download_patches() {
  local tag_arg=()
  if [ -n "$1" ] && [ "$1" != "latest" ]; then
    tag_arg=("$1")
  fi

  if gh release download ${tag_arg[@]+"${tag_arg[@]}"} --repo dh6k/morphe-patches --pattern "*.mpp" --dir "$TOOLS_DIR" 2>/dev/null; then
    mv "$TOOLS_DIR"/*.mpp "$TOOLS_DIR/patches.jar"
    return 0
  fi

  if gh release download ${tag_arg[@]+"${tag_arg[@]}"} --repo dh6k/morphe-patches --pattern "*.jar" --dir "$TOOLS_DIR" 2>/dev/null; then
    mv "$TOOLS_DIR"/*.jar "$TOOLS_DIR/patches.jar"
    return 0
  fi

  return 1
}

if download_patches "$PATCHES_TAG"; then
  DOWNLOADED="true"
else
  echo "Aviso: No se pudo descargar directamente con tag '$PATCHES_TAG', intentando con 'latest'..."
  if download_patches "latest"; then
    DOWNLOADED="true"
  fi
fi

if [ "$DOWNLOADED" != "true" ]; then
  echo "Error: No se pudo descargar el bundle de parches de dh6k/morphe-patches." >&2
  exit 1
fi

echo "=========================================================="
echo "==> 3. Verificando integraciones..."
echo "=========================================================="
if gh release download "$PATCHES_TAG" --repo dh6k/morphe-patches --pattern "*.apk" --dir "$TOOLS_DIR" 2>/dev/null; then
  mv "$TOOLS_DIR"/*.apk "$TOOLS_DIR/integrations.apk"
  echo "Integraciones descargadas de dh6k/morphe-patches."
elif gh release download --repo MorpheApp/morphe-patches --pattern "*.apk" --dir "$TOOLS_DIR" 2>/dev/null; then
  mv "$TOOLS_DIR"/*.apk "$TOOLS_DIR/integrations.apk"
  echo "Integraciones descargadas desde fallback MorpheApp/morphe-patches."
else
  echo "Nota: Integraciones incluidas dentro de patches.jar."
fi

# Guardar información exacta de herramientas
cat <<EOF > "$TOOLS_DIR/tools-info.json"
{
  "cli_version": "${CLI_TAG}",
  "patches_version": "${PATCHES_TAG}",
  "timestamp": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
EOF

echo "=========================================================="
echo "==> Herramientas preparadas en $TOOLS_DIR:"
ls -lh "$TOOLS_DIR"
cat "$TOOLS_DIR/tools-info.json"
echo "=========================================================="

echo "cli_version=$CLI_TAG" >> "$GITHUB_OUTPUT"
echo "patches_version=$PATCHES_TAG" >> "$GITHUB_OUTPUT"
