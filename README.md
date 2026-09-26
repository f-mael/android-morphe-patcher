# Android Brave Morphe Patcher

Pipeline de compilación automatizada para generar versiones parcheadas de Brave Browser para Android mediante Morphe CLI y parches de dh6k/morphe-patches.

## Características

- **Soporte de arquitecturas**: Compilación para `arm64-v8a` (`armv8`), `armeabi-v7a` (`armv7`) y paquetes multiarquitectura (`universal`).
- **Wallpaper personalizable**: Inclusión forzada de `Custom NTP wallpaper` para admitir fondos personalizados en la nueva pestaña (NTP).
- **Firma persistente**: Compatibilidad con keystore personalizado mediante GitHub Secrets para permitir actualizaciones continuas de la aplicación sin pérdida de datos, con fallback al keystore interno de depuración.
- **Optimizaciones dh6k**: Integración de `Brave Origin` (desbloqueo de funciones avanzadas y debloat) y `Brave Startup Performance Optimization` (reducción de tiempos de carga y eliminación de telemetría OEM).

## Compilación Manual (`workflow_dispatch`)

Para compilar bajo demanda una variante o arquitectura específica:

1. Ve a la pestaña **Actions** del repositorio.
2. Selecciona el workflow **Patch Brave Browser**.
3. Pulsa **Run workflow** y define los parámetros requeridos:

| Parámetro | Tipo | Opciones | Por defecto | Descripción |
| :--- | :--- | :--- | :--- | :--- |
| `brave_variant` | `choice` | `Stable`, `Beta`, `Nightly` | `Stable` | Canal oficial de distribución de Brave. |
| `architecture` | `choice` | `armv8`, `armv7`, `universal` | `armv8` | Arquitectura de la CPU objetivo. |
| `apk_url` | `string` | URL directa HTTP/HTTPS | *(vacío)* | URL opcional de un APK específico omitiendo la descarga desde releases oficiales. |

4. Pulsa **Run workflow**. La compilación individual toma entre 2 y 4 minutos.

## Automatización Periódica (`cron`)

El repositorio incluye un disparador programado que se ejecuta automáticamente cada 12 horas (`0 */12 * * *`):

- **Control de redundancia**: Antes de compilar, el workflow compara los tags de versión publicados en este repositorio frente a la última versión disponible en `brave/brave-browser` y `dh6k/morphe-patches`. Si no se detectan nuevas versiones, el proceso finaliza de forma limpia en segundos sin consumir minutos de Action.
- **Compilación en matriz**: Si se detecta una nueva versión de Brave o de los parches, se ejecuta una matriz paralela de 9 jobs que compila automáticamente todas las combinaciones de variantes (`Stable`, `Beta`, `Nightly`) y arquitecturas (`armv8`, `armv7`, `universal`).

## Configuración de Keystore para Forks

Para mantener una clave de firma idéntica entre compilaciones y permitir la actualización de la aplicación sin desinstalarla previamente, configura los siguientes secretos en **Settings > Secrets and variables > Actions**:

| Secreto | Descripción |
| :--- | :--- |
| `KEYSTORE_BASE64` | Archivo `.keystore` codificado en base64 en una sola línea. |
| `KEYSTORE_PASSWORD` | Contraseña del almacén de claves. |
| `KEYSTORE_ALIAS` | Alias de la clave dentro del keystore. |
| `KEYSTORE_ENTRY_PASSWORD` | Contraseña de la clave privada (opcional si es idéntica a `KEYSTORE_PASSWORD`). |

### Generación y codificación del Keystore

Para generar un keystore y obtener su representación en base64:

```bash
# Generar clave (si no dispones de una previa)
keytool -genkey -v -keystore release.keystore -alias brave-patch -keyalg RSA -keysize 2048 -validity 10000

# Codificar en base64 (Linux / macOS)
base64 -w 0 release.keystore

# Codificar en base64 (Windows PowerShell)
[Convert]::ToBase64String([IO.File]::ReadAllBytes("release.keystore"))
```

Si no se configuran estos secretos, Morphe CLI firmará el binario automáticamente con su clave de depuración predeterminada.

## Descargas

Los binarios generados se publican directamente en la sección de releases del proyecto:

- [Acceder a Releases](../../releases)
