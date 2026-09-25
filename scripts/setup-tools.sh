#!/usr/bin/env bash
# ==============================================================================
# Script: setup-tools.sh
# Descripción: Descarga y prepara Morphe CLI, el bundle de parches especificado
#              y el APK de integraciones (con fallback) en el directorio tools/.
# Uso: bash scripts/setup-tools.sh [REPO_PARCHES]
# Ejemplo: bash scripts/setup-tools.sh "dh6k/morphe-patches"
# ==============================================================================

set -euo pipefail

PATCHES_REPO="${1:-dh6k/morphe-patches}"
TOOLS_DIR="tools"

mkdir -p "$TOOLS_DIR"

echo "=========================================================="
echo "==> Configurando herramientas de parcheo"
echo "    Directorio destino : $TOOLS_DIR"
echo "    Repositorio parches: $PATCHES_REPO"
echo "=========================================================="

# ------------------------------------------------------------------------------
# 1. Descargar Morphe CLI (*all.jar) -> tools/cli.jar
# ------------------------------------------------------------------------------
echo "==> [1/3] Descargando Morphe CLI..."
if ! gh release download --repo MorpheApp/morphe-cli --pattern "*all.jar" --dir "$TOOLS_DIR" 2>/dev/null; then
  echo "    Intentando repositorio alternativo MorpheApp/morphe-desktop..."
  gh release download --repo MorpheApp/morphe-desktop --pattern "*all.jar" --dir "$TOOLS_DIR"
fi

CLI_FILE=$(find "$TOOLS_DIR" -maxdepth 1 -name "*all.jar" | head -n 1)
if [ -n "$CLI_FILE" ] && [ -f "$CLI_FILE" ]; then
  mv -f "$CLI_FILE" "$TOOLS_DIR/cli.jar"
  chmod +x "$TOOLS_DIR/cli.jar"
  echo "    Morphe CLI instalado en: $TOOLS_DIR/cli.jar"
else
  echo "Error: No se encontró el binario de Morphe CLI descargado (*all.jar)." >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 2. Descargar bundle de parches (*.jar o *.mpp) -> tools/patches.jar
# ------------------------------------------------------------------------------
echo "==> [2/3] Descargando bundle de parches desde $PATCHES_REPO..."
if gh release download --repo "$PATCHES_REPO" --pattern "*.jar" --dir "$TOOLS_DIR" 2>/dev/null; then
  PATCH_FILE=$(find "$TOOLS_DIR" -maxdepth 1 -name "*.jar" ! -name "cli.jar" | head -n 1)
  mv -f "$PATCH_FILE" "$TOOLS_DIR/patches.jar"
elif gh release download --repo "$PATCHES_REPO" --pattern "*.mpp" --dir "$TOOLS_DIR" 2>/dev/null; then
  PATCH_FILE=$(find "$TOOLS_DIR" -maxdepth 1 -name "*.mpp" | head -n 1)
  mv -f "$PATCH_FILE" "$TOOLS_DIR/patches.jar"
else
  echo "Error: No se encontró ningún archivo de parches (*.jar o *.mpp) en $PATCHES_REPO." >&2
  exit 1
fi
echo "    Bundle de parches guardado en: $TOOLS_DIR/patches.jar"

# ------------------------------------------------------------------------------
# 3. Descargar integrations APK (*integrations*.apk o *.apk) -> tools/integrations.apk
#    Primero se busca en el repositorio de parches, con fallback a MorpheApp/morphe-patches.
# ------------------------------------------------------------------------------
echo "==> [3/3] Buscando integrations APK..."
INTEGRATIONS_FOUND=false

# Intento 1: Repositorio de parches del usuario
if gh release download --repo "$PATCHES_REPO" --pattern "*integrations*.apk" --dir "$TOOLS_DIR" 2>/dev/null || \
   gh release download --repo "$PATCHES_REPO" --pattern "*.apk" --dir "$TOOLS_DIR" 2>/dev/null; then
  INTEGRATIONS_FILE=$(find "$TOOLS_DIR" -maxdepth 1 -name "*.apk" | head -n 1)
  if [ -n "$INTEGRATIONS_FILE" ] && [ -f "$INTEGRATIONS_FILE" ]; then
    mv -f "$INTEGRATIONS_FILE" "$TOOLS_DIR/integrations.apk"
    echo "    Integrations APK obtenido desde $PATCHES_REPO -> $TOOLS_DIR/integrations.apk"
    INTEGRATIONS_FOUND=true
  fi
fi

# Intento 2 (Fallback): MorpheApp/morphe-patches
if [ "$INTEGRATIONS_FOUND" = false ]; then
  if gh release download --repo MorpheApp/morphe-patches --pattern "*integrations*.apk" --dir "$TOOLS_DIR" 2>/dev/null || \
     gh release download --repo MorpheApp/morphe-patches --pattern "*.apk" --dir "$TOOLS_DIR" 2>/dev/null; then
    INTEGRATIONS_FILE=$(find "$TOOLS_DIR" -maxdepth 1 -name "*.apk" | head -n 1)
    if [ -n "$INTEGRATIONS_FILE" ] && [ -f "$INTEGRATIONS_FILE" ]; then
      mv -f "$INTEGRATIONS_FILE" "$TOOLS_DIR/integrations.apk"
      echo "    Integrations APK obtenido vía fallback desde MorpheApp/morphe-patches -> $TOOLS_DIR/integrations.apk"
      INTEGRATIONS_FOUND=true
    fi
  fi
fi

if [ "$INTEGRATIONS_FOUND" = false ]; then
  echo "    Aviso: No se encontró integrations APK independiente (las integraciones vienen integradas en el bundle de parches)."
fi

echo "=========================================================="
echo "==> Herramientas listas en $TOOLS_DIR/:"
ls -lh "$TOOLS_DIR"
echo "=========================================================="
