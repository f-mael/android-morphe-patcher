# 🦁 Brave Browser Android Patcher

Automatización del parcheo y compilación de **Brave Browser para Android** utilizando **Morphe CLI** y los parches de **[dh6k/morphe-patches](https://github.com/dh6k/morphe-patches)** con publicación directa en **GitHub Releases**.

---

## ⚡ Características

- **Descarga automática**: Obtiene la versión más reciente del APK oficial de Brave desde `brave/brave-browser` en GitHub según el canal y arquitectura elegidos.
- **Parches de dh6k**: Desbloqueo de opciones avanzadas y **Brave Origin**, fondos de pantalla personalizados en la nueva pestaña (NTP) y limpieza de telemetría.
- **Firma personalizable**: Soporte para keystore personalizado vía GitHub Secrets para mantener la misma firma entre actualizaciones, o uso del keystore de debug integrado por defecto.
- **Publicación directa**: Genera una release en GitHub con notas detalladas, versión de parches, fecha y hash SHA-256 del APK listo para instalar.

---

## 🚀 Cómo Ejecutar el Workflow

1. Ve a la pestaña **Actions** en tu repositorio de GitHub.
2. Selecciona el workflow **Patch Brave Browser** en la columna izquierda.
3. Haz clic en el botón desplegable **Run workflow** a la derecha.
4. Elige los parámetros deseados:

| Input | Tipo | Opciones | Default | Descripción |
| :--- | :--- | :--- | :--- | :--- |
| `brave_variant` | `choice` | `Stable`, `Beta`, `Nightly` | `Stable` | Canal oficial de Brave Browser. Determina si la release es final o pre-release. |
| `architecture` | `choice` | `armv8`, `armv7`, `universal` | `armv8` | Arquitectura de CPU del dispositivo Android. |
| `apk_url` | `string` | URL HTTP/HTTPS directa | *(vacío)* | Opcional. Permite forzar la descarga de un APK específico omitiendo la búsqueda automática. |

5. Pulsa en **Run workflow**. El proceso toma entre 2 y 4 minutos.

### Selección de Arquitectura
- **`armv8` (arm64-v8a)**: **Recomendado**. Para teléfonos y tablets modernos de 64 bits (descarga `Bravearm64Universal.apk`).
- **`armv7` (armeabi-v7a)**: Para teléfonos antiguos de 32 bits (descarga `BraveMonoarm.apk`).
- **`universal`**: Paquete multiarquitectura.

---

## 📥 Descarga del APK Parcheado

Una vez finalizada la ejecución:

1. Ve a la pestaña **Releases** en tu repositorio de GitHub (o al enlace directo en la barra lateral derecha).
2. Localiza la última versión publicada, nombrada:
   ```text
   Brave <Variante> (<Arquitectura>)
   ```
3. En la sección **Assets**, descarga directamente el archivo `.apk` parcheado:
   ```text
   brave-<Variante>-<Arquitectura>-patched.apk
   ```
4. Comprueba el hash SHA-256 incluido en la descripción de la release si deseas validar la integridad del archivo.

---

## 🔑 Firma Personalizada con Keystore (Opcional)

Si deseas actualizar la app en tu teléfono sin necesidad de desinstalarla en cada nueva versión, puedes configurar tu propio almacén de claves en **Settings > Secrets and variables > Actions**:

- `KEYSTORE_BASE64`: Contenido de tu archivo `.keystore` codificado en base64 (`base64 -w 0 mi_llave.keystore`).
- `KEYSTORE_PASSWORD`: Contraseña del keystore.
- `KEYSTORE_ALIAS`: Alias de la clave privada.
- `KEYSTORE_ENTRY_PASSWORD`: Contraseña del alias (si difiere de `KEYSTORE_PASSWORD`).

> [!NOTE]
> Si no configuras estos secretos, Morphe CLI firmará el APK automáticamente con su keystore integrado por defecto.

---

## 📲 Instalación en Android

> [!WARNING]
> La primera vez que instales esta versión parcheada, **debes desinstalar primero la versión oficial de Brave de Google Play Store** (debido a que las claves de firma criptográfica son diferentes). Recuerda respaldar tus marcadores y códigos de Brave Sync previamente.
