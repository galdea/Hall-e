# Hall-e para Android — borrador de ficha para Google Play (español latinoamericano)

Esta es la app de calendario complementaria de Hall-e. La versión original 0.1.0 funciona solo de forma local. La versión 0.2.0/código 3, que agrega grabación y reuniones compartidas opcionales, está disponible por ahora solo para las personas incluidas por el propietario en la prueba interna de Google Play; este borrador describe esa versión para una futura publicación pública. Los espacios compartidos coordinan datos seleccionados de reuniones con dispositivos vinculados de Hall-e, incluido Hall-e para Mac.

Las fichas completas en inglés y español y las capturas reales `03-shared-sessions.png` y `04-local-recording.png` están guardadas en Play Console para la versión candidata 0.2.0/código 3. En Console, el ícono de la app y el gráfico destacado están marcados como generados con IA. El propietario confirmó explícitamente el envío de 15 cambios. Publishing overview indica: “Your changes are now in review. We may find additional issues when reviewing your app.” Las comprobaciones rápidas terminaron correctamente. La versión 1 de la prueba cerrada para el código 3 está configurada solo para Chile y conserva la lista del propietario, con una persona; todavía no está activa ni es pública. La prueba interna del código 3 sigue activa y no es una publicación pública.

## Ficha de Play

- **Nombre de la app (29/30):** Hall-e: Reuniones y Proyectos
- **Descripción breve (73/80):** Reuniones al instante, grabación local y sesiones compartidas con tu Mac.
- **Descripción completa (menos de 4.000 caracteres):**

  Organiza tu día con más calma y claridad con Hall-e.

  **Revisa tu día de un vistazo**
  Elige qué calendarios de tu teléfono quieres ver en Hall-e. Revisa un día a la vez, consulta los datos de cada reunión y abre los enlaces compatibles con la app o el navegador que ya usas.

  **Ten a mano el contexto de tus proyectos**
  Agrupa reuniones en proyectos locales. Escribe o actualiza una nota Markdown para una reunión y compártela cuando quieras desde el menú para compartir de Android.

  Crea una reunión al instante con título, fecha y hora; asígnala a un proyecto existente o crea uno. En un espacio vinculado opcional, puedes solicitar el traspaso de la grabación entre dispositivos; en cada uno se requiere iniciar la grabación explícitamente y conceder el permiso de micrófono.

  **Programa recordatorios**
  Elige un aviso al inicio de la reunión, 1, 5, 10, 15 o 30 minutos antes, o define un intervalo personalizado. Si está activado, el resumen de la mañana aparece la primera vez que abres Hall-e desde las 4:00 hasta antes del mediodía.

  **Tu calendario permanece en el teléfono**
  Hall-e lee solo los calendarios que seleccionas. Las entradas del calendario, las notas y los ajustes de recordatorios se guardan localmente. Si eliges vincular un espacio compartido, los títulos de reuniones seleccionados, nombres opcionales de proyectos o enlaces y horarios se cifran en el teléfono y se envían, junto con metadatos de coordinación, al servidor de Hall-e para los dispositivos vinculados. En este flujo de espacio compartido no se envían al coordinador identificadores del calendario, listas de asistentes, registros completos del calendario ni audio. No hay sincronización automática de calendarios, notas, proyectos ni audio. Hall-e no tiene un sistema de cuentas.

  La grabación es opcional y captura audio solo del micrófono de este teléfono, después de que eliges grabar y concedes el permiso. Android u otra app puede afectar la captura; quizá no incluya a participantes remotos ni el audio de otras apps. Hall-e no sube las grabaciones automáticamente ni las envía a su coordinador. Puedes exportar una grabación de forma explícita desde el menú para compartir de Android y elegir un destino; la app o el servicio receptor podría procesar o conservar el archivo según sus propias prácticas de privacidad. Hall-e no transcribe conversaciones ni solicita acceso a contactos o ubicación.

  Android controla el permiso de calendario, el permiso para notificaciones y el acceso a alarmas exactas. Si alguno está desactivado, los recordatorios pueden no aparecer o llegar más tarde de lo previsto. El resumen de la mañana aparece cuando abres Hall-e desde las 4:00 hasta antes del mediodía; Android no necesariamente iniciará la app antes de que la abras.

- **Contacto de soporte:** gabriel.aldea@gmail.com (correo público de soporte publicado; Hall-e no afirma ser propietario del dominio hall-e.com).
- **URL de la política de privacidad:** https://hall-e.pages.dev/android-privacy.html (guardada en Play Console; Publishing overview indica que los cambios están en revisión y las comprobaciones rápidas terminaron correctamente). La `PRIVACY.md` principal describe la app para Mac y no reemplaza la información de Android.
- **Categoría sugerida:** Productividad
- **Etiquetas sugeridas:** Calendario, Productividad

## Recursos gráficos

- **Ícono:** [`hall-e-play-icon-512.png`](hall-e-play-icon-512.png), marcado en Play Console como generado con IA.
- **Gráfico destacado:** [`feature-graphic-1024x500.png`](feature-graphic-1024x500.png), marcado en Play Console como generado con IA. No contiene pantallas simuladas ni capturas inventadas.
- **Fuente editable y pasos para regenerar:** [`generate-assets.py`](generate-assets.py) (Python 3 y Pillow).
- **Capturas:** [`03-shared-sessions.png`](screenshots/03-shared-sessions.png) y [`04-local-recording.png`](screenshots/04-local-recording.png) son capturas reales de QA, recortadas y redimensionadas de forma mecánica; su procedencia está en [`provenance.md`](screenshots/provenance.md). Están guardadas en la ficha de Play; no son imágenes generadas con IA ni están etiquetadas como tales. Usa estas en lugar de la captura 01 obsoleta.
