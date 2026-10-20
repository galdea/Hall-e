# Hall-e para Android — borrador de ficha para Google Play (español latinoamericano)

Esta es la app de calendario complementaria de Hall-e. La versión publicada 0.1.0 funciona solo de forma local. Las funciones opcionales de grabación y reuniones compartidas que se describen aquí están previstas para la versión 0.2.0; los espacios compartidos pueden coordinar datos seleccionados de reuniones con dispositivos vinculados de Hall-e, incluido Hall-e para Mac.

## Ficha de Play

- **Nombre de la app (26/30):** Hall-e: Agenda y reuniones
- **Descripción breve (64/80):** Tu calendario, enlaces, notas y recordatorios, en este teléfono.
- **Descripción completa (menos de 4.000 caracteres):**

  Organiza tu día con más calma y claridad con Hall-e.

  **Revisa tu día de un vistazo**
  Elige qué calendarios de tu teléfono quieres ver en Hall-e. Revisa un día a la vez, consulta los datos de cada reunión y abre los enlaces compatibles con la app o el navegador que ya usas.

  **Ten a mano el contexto de tus proyectos**
  Agrupa reuniones en proyectos locales. Escribe o actualiza una nota Markdown para una reunión y compártela cuando quieras desde el menú para compartir de Android.

  **Programa recordatorios**
  Elige un aviso al inicio de la reunión, 1, 5, 10, 15 o 30 minutos antes, o define un intervalo personalizado. Si está activado, el resumen de la mañana aparece la primera vez que abres Hall-e desde las 4:00 hasta antes del mediodía.

  **Tu calendario permanece en el teléfono**
  Hall-e lee solo los calendarios que seleccionas. Las entradas del calendario, las notas y los ajustes de recordatorios se guardan localmente. Si eliges vincular un espacio compartido, los títulos de reuniones seleccionados, nombres opcionales de proyectos o enlaces y horarios se cifran en el teléfono y se envían, junto con metadatos de coordinación, al servidor de Hall-e para los dispositivos vinculados. No se envían identificadores de calendario, listas de asistentes, registros completos del calendario ni audio. No hay sincronización automática de calendarios, notas, proyectos ni audio. Hall-e no tiene un sistema de cuentas.

  La grabación es opcional y captura audio solo del micrófono de este teléfono, después de que eliges grabar y concedes el permiso. Android u otra app puede afectar la captura; quizá no incluya a participantes remotos ni el audio de otras apps. El audio permanece en el teléfono y nunca se envía al servidor. Hall-e no transcribe conversaciones ni solicita acceso a contactos o ubicación.

  Android controla el permiso de calendario, el permiso para notificaciones y el acceso a alarmas exactas. Si alguno está desactivado, los recordatorios pueden no aparecer o llegar más tarde de lo previsto. El resumen de la mañana aparece cuando abres Hall-e desde las 4:00 hasta antes del mediodía; Android no necesariamente iniciará la app antes de que la abras.

- **URL de soporte:** https://github.com/galdea/Hall-e/issues/new/choose
- **URL de la política de privacidad:** https://hall-e.pages.dev/android-privacy.html. La `PRIVACY.md` principal describe la app para Mac y no reemplaza la información de Android.
- **Categoría sugerida:** Productividad
- **Etiquetas sugeridas:** Calendario, Productividad

## Recursos gráficos

- **Ícono:** [`hall-e-play-icon-512.png`](hall-e-play-icon-512.png), generado al redimensionar el ícono existente en `docs/assets/hall-e.png`.
- **Gráfico destacado:** [`feature-graphic-1024x500.png`](feature-graphic-1024x500.png), compuesto con el ícono y los colores de marca de Hall-e. No contiene pantallas simuladas ni capturas inventadas.
- **Fuente editable y pasos para regenerar:** [`generate-assets.py`](generate-assets.py) (Python 3 y Pillow).
- **Capturas de pantalla:** Toma capturas reales de una versión Android en ejecución antes de enviar la ficha. Este paquete no incluye mockups de pantallas.
