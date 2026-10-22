# android-morphe-patcher

Compilaciones automatizadas de Brave Browser para Android parcheadas con Morphe (`dh6k/morphe-patches`).

### Qué incluye este repositorio

- **Binarios listos para usar**: APKs parcheados de Brave (`Stable`, `Beta`, `Nightly`) para arquitecturas `arm64-v8a`, `armeabi-v7a` y `universal`.
- **Doble variante visual**:
  - **Estándar**: Tema oscuro original de Brave con optimizaciones.
  - **AMOLED**: Tema negro puro (`#000000`) sin grises ni Material You, ideal para pantallas OLED.
- **5 parches dedicados de Brave**:
  1. **Brave Origin**: Desbloqueo de controles y funciones avanzadas de Brave Origin.
  2. **Brave Startup Performance Optimization**: Eliminación de llamadas y sobrecarga de personalizaciones OEM en el arranque.
  3. **Custom NTP wallpaper**: Integración de fondo de pantalla personalizado en la Nueva Pestaña (`assets/wallpaper.png`).
  4. **Brave NTP four-column tiles**: Mantiene los accesos rápidos en cuadrícula de 4 columnas hacia abajo aun con fondo activado.
  5. **Brave AMOLED theme** *(variante AMOLED)*: Superficies en negro absoluto `#000000` y desactivación de Material You.
- **Entregas automáticas unificadas**: Generación periódica y firma de todos los APKs agrupados en una sola entrega en la sección de [Releases](../../releases).
