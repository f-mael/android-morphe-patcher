# android-morphe-patcher

Compilaciones automatizadas de **Brave Browser** para Android parcheadas con **Morphe** ([dh6k/morphe-patches](https://github.com/dh6k/morphe-patches)).

---

## 🚀 Qué incluye este repositorio

- **Binarios listos para usar**: APKs parcheados de Brave (`Stable`, `Beta`, `Nightly`) para arquitecturas `armv8`, `armv7` y `universal`.
- **Doble variante visual**:
  - **Estándar**: Tema oscuro por defecto de Brave con optimizaciones.
  - **🖤 AMOLED**: Tema negro puro (`#000000`) sin tonos grises ni interferencia de Material You, diseñado para pantallas OLED.
- **5 parches dedicados de Brave**:
  1. **Brave Origin**: Desbloqueo de controles y opciones avanzadas de Brave Origin.
  2. **Brave Startup Performance Optimization**: Eliminación de llamadas y sobrecarga de operadoras/OEM en el arranque.
  3. **Custom NTP wallpaper**: Integración de fondo personalizado en la Nueva Pestaña (`assets/wallpaper.png`).
  4. **Brave NTP four-column tiles**: Conserva los accesos rápidos en cuadrícula de 4 columnas descendente aun con fondo activo.
  5. **Brave AMOLED theme** *(variante AMOLED)*: Fondo negro puro `#000000` y desactivación de dynamic colors.
- **Entregas automáticas unificadas**: Generación periódica (cada 24 horas) y firma de todos los APKs en una única release en la sección de [Releases](../../releases).

> [!NOTE]
> Las notas de cada release indican los parches **realmente aplicados**. Si un parche deja de ser compatible con una versión nueva de Brave, se omite, se registra como advertencia y el resto de la compilación continúa. La release falla si no se aplica ningún parche o si se pidió la variante AMOLED y su parche no está disponible.

---

## 📲 Guía de instalación

> [!IMPORTANT]
> **Firma digital diferente a la oficial**: Los APKs parcheados están firmados con una clave distinta a la oficial de Brave Browser en Google Play.
> - Si tienes instalada la versión oficial de la tienda, **debes desinstalarla primero** antes de instalar este APK.
> - No se recibirán actualizaciones automáticas desde Google Play. Para actualizar, descarga la nueva versión desde la pestaña [Releases](../../releases).
> - Si configuras tu propio `KEYSTORE` en el repositorio, podrás actualizar tus instalaciones instalando el nuevo APK encima sin perder datos.

---

## 📱 Mapeo de arquitecturas

Para elegir el APK correcto según tu dispositivo:

| Arquitectura en Release | Arquitectura Android (ABI) | Dispositivos compatibles |
| :--- | :--- | :--- |
| **`armv8`** | `arm64-v8a` | La gran mayoría de smartphones modernos de 64 bits (Recomendado). |
| **`armv7`** | `armeabi-v7a` | Dispositivos antiguos de 32 bits. |
| **`universal`** | Universal | Compatible con cualquier procesador (archivo de mayor tamaño). |

---

## 🔒 Verificación de integridad (SHA-256)

Cada release incluye un archivo `checksums.txt` para verificar que el APK descargado no esté corrupto ni haya sido alterado:

```bash
# En Linux / macOS / Termux:
sha256sum -c checksums.txt --ignore-missing

# En Windows (PowerShell):
Get-FileHash .\brave-Stable-armv8-patched.apk -Algorithm SHA256
```

---

## ⚙️ Configuración de Secretos (Opcional)

Si deseas firmar los APKs con tu propia clave para mantener la misma firma entre versiones, agrega estos secretos en **Settings > Secrets and variables > Actions**:

| Secreto | Descripción |
| :--- | :--- |
| `KEYSTORE_BASE64` | Archivo keystore codificado en Base64 (`base64 -w 0 mi-keystore.keystore`). |
| `KEYSTORE_PASSWORD` | Contraseña del archivo keystore. |
| `KEYSTORE_ALIAS` | Alias de la clave dentro del keystore. |
| `KEYSTORE_ENTRY_PASSWORD` | *(Opcional)* Contraseña del alias de la clave (si difiere de la principal). |

*Si no se configuran estos secretos, Morphe CLI firmará automáticamente con un keystore de depuración predeterminado.*

> [!WARNING]
> El keystore de depuración de Morphe es **público y compartido** por todas las compilaciones que no configuran secretos. Cualquiera podría generar un APK con la misma firma. Configura tu propio `KEYSTORE_BASE64` si vas a instalar estos APKs en un dispositivo real o a distribuirlos.

---

## 🛠️ Ejecución manual (`workflow_dispatch`)

Puedes compilar manualmente desde la pestaña **Actions > Patch Brave Browser > Run workflow**:

- **Variante**: `all` (todas), `Stable`, `Beta`, o `Nightly`.
- **Arquitectura**: `all` (todas), `armv8`, `armv7`, o `universal`.
- **Tema**: `all` (ambas), `standard`, o `amoled`.
- **URL APK personalizada**: *(Opcional)* Enlace directo a un archivo APK de Brave específico.

Algunas consideraciones sobre ejecuciones manuales:

- Una compilación **parcial** (por arquitectura o por tema) crea su **propia release**, con el sufijo correspondiente en el tag (por ejemplo `brave-v1.98.60-v1.9.0-armv8-amoled`), para no sobrescribir las notas ni los checksums de la release completa.
- Si indicas una **URL de APK personalizada**, se genera un único APK a partir de ese archivo (un solo job, sin división por arquitectura) y una release independiente con marca de tiempo.
- Si pides explícitamente `Beta` o `Nightly` y esa variante no tiene APKs publicados, el workflow falla con un error en lugar de compilar Stable con una etiqueta equivocada.

---

## 🧩 Estructura del proyecto

| Ruta | Descripción |
| :--- | :--- |
| `.github/workflows/patch-brave.yml` | Pipeline principal: resolución de versiones, matriz, compilación y publicación. |
| `.github/workflows/lint.yml` | Análisis estático de scripts (`shellcheck`) y workflows (`actionlint`). |
| `scripts/resolve-matrix.sh` | Resuelve versiones upstream y decide qué compilar (incluye la detección de cambios del cron). |
| `scripts/setup-tools.sh` | Descarga Morphe CLI y el bundle de parches, y registra sus versiones. |
| `scripts/build-apk.sh` | Descarga el APK base, aplica los parches y genera APKs + metadatos + checksums. |
| `scripts/publish-release.sh` | Consolida artefactos, genera las notas de release y publica en GitHub Releases. |
| `assets/wallpaper.png` | Imagen usada por el parche `Custom NTP wallpaper`. |

---

## 📄 Licencia

Este proyecto se distribuye bajo los términos de la licencia [GNU General Public License v3.0 (GPL-3.0)](LICENSE).

- **Brave Browser** es una marca y software propiedad de *Brave Software, Inc.*, licenciado bajo la licencia *Mozilla Public License 2.0 (MPL-2.0)*. Este proyecto no está respaldado ni afiliado con Brave Software.
- **Morphe Patches** son desarrollados por el equipo de Morphe bajo licencia *GPL-3.0*.
