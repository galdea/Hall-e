# Agenda privada de Hall-e en Mac y Android

Esta rama de desarrollo implementa una cuenta y un calendario propios de Hall-e. El móvil puede grabar sin conexión y conservar el archivo. Cuando recupera la red puede enviarlo al servicio HTTPS elegido, que procesa la grabación y publica el resultado para la misma cuenta. Para usarlo fuera de las pruebas locales hace falta configurar ese servicio.

## Recorrido en las aplicaciones

1. En Mac, abre **Hoy → Calendario de la cuenta**. En Android, abre **Account calendar** desde la pantalla principal. Las vistas de día, semana y mes del Mac muestran las reuniones privadas. En Android se pueden ver por fecha o todas juntas. Introduce el mismo origen HTTPS en ambos equipos y accede con Google o mediante el código recibido por correo. La cuenta se identifica por un UUID interno. Para añadir otro método, entra con el método existente y elige **Vincular otro método**.
2. Crea una reunión con título y horas en cualquiera de los equipos. Abre el calendario de la misma cuenta en el otro. Puedes editar o borrar la reunión en ambos. Los clientes conservan los cambios pendientes en disco y vuelven a consultar el estado compartido. Ante ediciones incompatibles conservan el cambio local pendiente de revisión.
3. En Android, abre la reunión, elige **Record phone microphone**, confirma el consentimiento de los participantes y selecciona el destino. Puedes guardar el audio únicamente en el teléfono o autorizar su envío a la cuenta y al proveedor indicado. Android solicita acceso al micrófono y muestra una notificación mientras graba. **Stop recording** finaliza el archivo. Una grabación local terminada también se puede enviar después.
4. Consulta el estado y el texto en la reunión desde cualquier dispositivo conectado a esa cuenta. Tras perder la red, Android conserva archivo, identificador y progreso. El sistema programa trabajo con conectividad y la agenda vuelve a intentarlo al abrirse. El Mac puede estar apagado. Android controla el momento de ejecución en segundo plano.

## Qué había en el repositorio

La base verificada es `galdea/Hall-e`, `main` en `9bc179754f7bf8f94d614d5abe127ab123683262`. La aplicación instalada de Mac se identifica como `cl.gabriel.hall-e`, versión 0.5.1. En el código, Android usa `app.halle.companion` y el build de desarrollo añade `.preview`. También existe un preview de Windows. Este cambio abarca macOS y Android. El repositorio no incluye un cliente iOS.

| Componente existente | Comportamiento observado | Integración de esta rama |
| --- | --- | --- |
| Calendario de escritorio | EventKit y Google Calendar de solo lectura alimentan una agenda local. La consulta Google usa una ventana temporal y excluye borrados. | Entrada desde Hoy a la agenda de cuenta. La importación de una ocurrencia con hora requiere seleccionarla. |
| Android | Lee CalendarContract. La grabadora usa MediaRecorder, el micrófono y AAC en MPEG-4, con servicio en primer plano y recuperación de archivos interrumpidos. | Reutiliza la grabadora y separa los archivos y la cola por cuenta y servidor. |
| Grabación en Mac | La edición directa admite micrófono y audio de una aplicación compatible. La edición de la tienda usa micrófono. La cadena de transcripción incluye Deepgram, Speechmatics y Apple Speech según configuración, permisos y disponibilidad. | La nueva agenda lee el resultado remoto. La biblioteca, captura y procesamiento originales conservan sus formatos y su selección de proveedor. |
| Emparejamiento | Un Worker de Cloudflare y un Durable Object por espacio coordinan invitaciones, metadatos cifrados y turnos de grabación por Internet. | El Worker de cuentas tiene rutas, credenciales y almacenamiento independientes. Una invitación de emparejamiento no concede acceso a la cuenta. |
| Web | Sitio estático de descargas en Cloudflare Pages. | Puede previsualizarse como contenido estático. La grabación y el servicio de cuentas funcionan con clientes nativos. |

La captura Android recoge lo que oye el micrófono. Durante una llamada, el sistema u otra aplicación puede silenciarlo o impedir que se oigan participantes remotos. Abrir un enlace de Meet, Zoom o Teams abre el servicio correspondiente. No hay un bot de reunión, un conector de audio ni una prueba de captura del sonido interno en el móvil.

## Identidad, calendario y almacenamiento

- El Worker solicita a Google `openid email`, verifica firma, emisor, audiencia, expiración y nonce, y vincula el identificador permanente de Google a un usuario de Hall-e. La autorización de navegador usa PKCE, un retorno HTTPS fijo, estado de un solo uso y una confirmación de ocho dígitos que se introduce en la app. Los códigos por correo caducan a los diez minutos. Un correo coincidente entre métodos requiere vinculación explícita. Las sesiones de los equipos se revocan individualmente.
- La clave de un registro privado incluye el propietario autenticado. Las reuniones usan UUID y un número de revisión. Cada edición lleva la revisión de partida y un identificador de operación persistido antes del envío. D1 acepta edición y recibo dentro de la misma transacción. Si se pierde una respuesta, repetir la operación devuelve el estado actual. El borrado deja una marca que evita resucitar la reunión durante la sincronización posterior.
- Las fechas de reuniones propias se envían como instantes ISO 8601 con zona y se normalizan a UTC. La agenda reconstruye la hora de visualización local. No se deduplican reuniones diferentes por coincidencia de título u hora.
- Android guarda el AAC original en su directorio privado. La API recibe partes de hasta 8 MiB y archivos de hasta 256 MiB, valida longitud y SHA-256, y encola un único trabajo tras comprobar todos los bytes. En R2 los nombres de los objetos son opacos y las lecturas y escrituras pasan por el Worker autenticado. Los secretos de proveedor se configuran en el servidor.
- El trabajo persiste en D1. Un disparador programado reclama una fila, procesa o consulta al proveedor y guarda el resultado para ambos clientes. El envío a Deepgram solicita Nova-3, formato legible, diarización y exclusión de entrenamiento. Speechmatics conserva región e ID del trabajo antes de consultar su resultado. Un envío que pudo haberse aceptado queda en revisión y evita una segunda petición automática de pago. El formato compartido lleva texto, turnos y tiempos disponibles. La biblioteca Mac conserva también sus artefactos ricos locales.
- Cerrar sesión oculta esa agenda y conserva la cola en el espacio de su propietario. La caché se separa por origen HTTPS y usuario. Mac usa Keychain para las credenciales. Android las protege mediante Android Keystore. Un dispositivo desconectado aprende de la revocación al reconectar. Los archivos ya recibidos quedan sujetos a los controles del dispositivo.

## Historial e importación voluntaria

La migración es aditiva. Los esquemas `coordinator/account*.sql` pertenecen a una base dedicada. La SQLite original de Hall-e, los espacios emparejados y los originales de grabaciones permanecen en sus ubicaciones.

- En Mac puedes copiar el título y las fechas de una ocurrencia local con hora. El selector también recupera reuniones pasadas con una grabación terminada y metadatos de calendario válidos. Un reintento de grabación incompleto conserva la ocurrencia anterior. Una cancelación en la agenda actual tiene prioridad. Si ya confirmaste su proyecto, puedes elegir incluirlo. Hall-e muestra el nombre antes de copiarlo y crea un identificador propio de esa cuenta. También puedes añadir el proyecto a una copia anterior que siga sin asignar. En Android puedes seleccionar una reunión guardada localmente y copiar su título y fechas. Los asistentes, las notas, el enlace de llamada y las credenciales permanecen en el dispositivo. Repetir la misma selección en ese origen usa el mismo ID. Las copias explícitas de fuentes diferentes conservan identidades distintas.
- En Mac puedes seleccionar una transcripción local terminada y copiar su texto a una reunión privada. La copia evita una nueva transcripción y no transmite el archivo de audio. Puedes retirar el texto compartido y conservar el original. La API rechaza un reintento antiguo si la copia ya fue retirada.
- Borrar una reunión privada oculta los resultados en la API. Se elimina el texto importado y el proceso programado limpia los objetos de audio y las transcripciones de esa reunión. Las cargas incompletas inactivas se limpian tras siete días. Los dispositivos desconectados aplican el cambio al volver a sincronizar. La retención del proveedor y la de las copias locales son independientes.
- Para volver al flujo anterior, cierra sesión y usa la agenda y la biblioteca locales. El operador puede desactivar el Worker privado y conservar aparte su base y su bucket para revertir la activación. No hay que restaurar ni sobrescribir la biblioteca original. Si se quiere retirar contenido compartido, debe eliminarse desde la agenda conectada antes de desactivar el servicio.

## Google Calendar

El inicio de sesión no concede acceso a un calendario externo. Una reunión de la cuenta Hall-e se edita en el calendario interno. La importación por selección crea una copia. Cambios de la copia no se escriben en Google, Apple Calendar ni el calendario Android.

Para añadir en el futuro un espejo de Google, haría falta autorización de lectura independiente y correspondencia por cuenta, calendario e ID de evento. Una serie recurrente necesita distinguir cada ocurrencia por su inicio original, incluso si se reprograma. Un día completo necesita conservar la fecha civil y zona. Aplicar todas las páginas antes de guardar `nextSyncToken`, procesar cancelaciones y, ante un `410`, reconstruir únicamente la réplica de ese calendario. La ausencia en una consulta por fechas no prueba un borrado. [Sincronización incremental de Google](https://developers.google.com/workspace/calendar/api/guides/sync) · [Eventos y ocurrencias](https://developers.google.com/workspace/calendar/api/v3/reference/events)

## Elección de infraestructura

| Opción | Papel evaluado | Decisión |
| --- | --- | --- |
| Vercel | Web estática o preview. Workflow permite retomar pasos duraderos, conservar resultados y reintentar trabajo. | Separar aceptación, envío y recuperación del resultado. En Workflow se pasarían identificadores opacos y referencias privadas a archivos para limitar lo que queda en el historial de ejecución. |
| Cloudflare | Workers, D1 para identidad, revisiones y trabajos, R2 privado para audio. El repositorio ya usa Workers y Pages. | Se implementó un segundo Worker con un registro durable de trabajos en D1. Evita configurar otro sistema de colas para el corte vertical. Cloudflare Queues sería una opción al aumentar volumen. Sus entregas repetidas seguirían exigiendo idempotencia. |
| Dispositivo | Caché, cola de cambios y original del audio. | Permite grabar sin conexión. El servidor de cuenta puede continuar el procesamiento cuando el ordenador está apagado. |

Se leyeron y aplicaron las skills **Workflow** y **Vercel Functions** disponibles en la caché local del plugin de Vercel, revisión `d420d130`, y se contrastaron con la documentación oficial. No se instaló el plugin ni se vinculó un proyecto. [Directorio oficial de skills](https://vercel.com/docs/agent-resources/skills) · [Vercel Workflow](https://vercel.com/docs/workflow) · [Límites de Functions](https://vercel.com/docs/functions/limitations) · [Transacciones por lote en D1](https://developers.cloudflare.com/d1/worker-api/d1-database/) · [Garantías de entrega de Queues](https://developers.cloudflare.com/queues/reference/delivery-guarantees/)

## Contrato del servicio y reproducción local

El punto de entrada es `coordinator/src/account-worker.mjs`. La configuración `coordinator/wrangler.account.local.jsonc` describe recursos locales sin rutas públicas. La prueba de runtime prepara automáticamente D1 y R2 temporales. Los comandos se ejecutan desde la raíz del repositorio.

```sh
npm test --prefix coordinator
# ACCOUNT_WORKER_TOOLS apunta a un node_modules local que ya contiene Miniflare y esbuild.
node coordinator/scripts/account-workerd-smoke.mjs
```

La prueba de runtime necesita Node con `node:sqlite`, Miniflare, esbuild y permiso para escuchar en loopback. Genera una clave RSA de prueba y sustituye **todas** las peticiones salientes. No necesita credenciales de cuenta, ni accede a micrófonos o bibliotecas. La suite de Node funciona sin Miniflare. Para preparar una instalación aislada, los archivos `coordinator/account-*.sql` se aplican por orden alfabético a su D1 dedicada.

| Recurso relativo a `/account/v1` | Uso |
| --- | --- |
| `POST auth/email/start`, `POST auth/email/verify` | Solicitud y confirmación de código. |
| `POST auth/browser/start`, `GET auth/browser/callback`, `POST auth/browser/finish` | Google en navegador del sistema, confirmación en el dispositivo iniciador y sesión propia de Hall-e. |
| `GET auth/session`, `POST auth/logout` | Comprobar y revocar la sesión del dispositivo. |
| `GET meetings`, `GET meetings?since=<version>` | Estado privado y marcas de borrado. Una versión vigente permite responder sin volver a leer ni enviar las transcripciones. |
| `PUT meetings/:id` | Crear, cambiar o borrar con `baseRevision`, `mutationId` y, para borrar, `deleted: true`. Un conflicto devuelve HTTP 409. |
| `PUT meetings/:id/recordings/:rid`, `PUT …/parts/:n`, `POST …/complete` | Consentimiento, manifiesto, partes numeradas desde cero y confirmación. `GET` del recurso de grabación devuelve estado y texto. |
| `PUT meetings/:id/imports/:importId`, `DELETE …/:importId` | Copiar o retirar una transcripción local que seleccionó el usuario. |

Al empaquetar las aplicaciones para un servicio ya habilitado, configura `HALLE_ACCOUNT_ORIGIN` con su origen HTTPS. La dirección queda disponible en ambas pantallas de inicio de sesión. Una dirección elegida por el usuario tiene prioridad. Si se omite, la dirección inicial queda en blanco.

**Configuración prevista para un entorno autorizado.** `ACCOUNT_DB` es el binding de D1 y `ACCOUNT_AUDIO` el del bucket R2 privado. La autenticación usa `ACCOUNT_AUTH_SECRET`. El correo admite un servicio privado `ACCOUNT_MAILER` o `ACCOUNT_RESEND_KEY` y `ACCOUNT_MAIL_FROM`. Google usa un cliente web con `ACCOUNT_GOOGLE_CLIENT_ID`, `ACCOUNT_GOOGLE_CLIENT_SECRET` y `ACCOUNT_PUBLIC_ORIGIN`. El retorno registrado debe ser ese origen seguido de `/account/v1/auth/browser/callback`. Ninguno de estos secretos se distribuye con los clientes.

El proceso de transcripción comprueba `ACCOUNT_ENABLE_TRANSCRIPTION` y la configuración del proveedor. Deepgram usa `ACCOUNT_DEEPGRAM_KEY`. Speechmatics usa `ACCOUNT_SPEECHMATICS_KEY`, una `ACCOUNT_SPEECHMATICS_REGION` que coincida con la consentida y `ACCOUNT_SPEECHMATICS_TRAINING_OPT_OUT` confirmado por el operador. La opción Android de esta versión identifica la región europea. El job queda pendiente si la configuración necesaria no está disponible. El cron procesa como máximo un trabajo por invocación.

## Revisión independiente y pruebas

La [batería de historias de usuario](historias-cuenta-proyectos.md) cubre también la relación entre reuniones y proyectos en Mac y Android.

Participaron dos modelos internos. **gpt-6.2-astra** revisó la arquitectura, identificó la frontera del coordinador de emparejamiento y comprobó el Worker sobre `workerd`. **gpt-6.2-sol** revisó privacidad y pruebas. Señaló el caso en que la carga incompleta caduca mientras el teléfono conserva un índice de parte antiguo. El cliente vuelve a enviar las partes ante `missing_parts`. Ambas revisiones coincidieron en que la idempotencia de una carga no demuestra que un proveedor externo haya aceptado o rechazado una petición cuya respuesta se perdió. Ese caso termina en revisión.

| Capa | Evidencia |
| --- | --- |
| Base original | 13 pruebas del coordinador de emparejamiento, 14 de Android y 6 de OAuth/PKCE en Mac. |
| API de cuentas y coordinador | Pasaron 38 pruebas de Node. Se verificó el flujo con SQLite reabierta entre etapas, dos sesiones de un usuario, un usuario distinto, vinculación, revocación, fechas, concurrencia, replay, borrados, importación y exclusión de acceso cruzado. Los adaptadores de Deepgram y Speechmatics se ejercitaron con respuestas sintéticas, incluida la recuperación del identificador remoto. |
| Runtime Cloudflare | `workerd`, D1 y R2 locales. Un tono AAC sintético de 440 Hz en un contenedor MPEG-4 de 8 MiB + 64 bytes se dividió en dos partes. Se repitieron una parte, el cierre y el cron. El proveedor simulado recibió un envío y ambas sesiones leyeron la transcripción. También se comprobó en ese runtime la carga multipart de Speechmatics, su único envío, la consulta del trabajo y su texto con hablante, además de Google con JWKS/PKCE y correo simulado. Se corrigió una incompatibilidad de `fetch` con redirecciones que no reproducía Node. |
| Mac | Pasaron 56 pruebas en seis suites. Compilación Swift, prueba de pérdida de respuesta, reapertura de la cola y cambio de usuario con URLProtocol, Keychain simulado y archivos temporales. Pruebas de la agenda, fechas, captura, OAuth y adaptadores de transcripción. |
| Android | Pasaron las 19 pruebas y se compiló el APK de depuración con Gradle 9.1 y SDK 36. Pruebas JVM del alcance de las cuentas, reanudación por partes y pérdida de la respuesta de confirmación. La grabación usa el servicio de micrófono existente. |

## Qué falta verificar antes de usar cuentas reales

1. En un teléfono físico, con reunión y audio sintéticos, comprobar permiso denegado y concedido, notificación de grabación, apagado de pantalla, pérdida de red, cierre del proceso, reinicio y recuperación con el Mac apagado. Verificar que al cambiar de usuario no aparecen ni se envían los archivos de la cuenta anterior. Las pruebas de esta rama no midieron calidad acústica ni comportamiento del micrófono durante una videollamada.
2. Con autorización separada, configurar un origen HTTPS de pruebas, probar entrega de correo y el retorno registrado de Google desde el navegador de ambos sistemas. Validar envío sintético con cada proveedor bajo su configuración real antes de habilitarlo para otras cuentas.
3. Medir la carga al límite de 256 MiB, el tiempo de sincronización tras una ausencia larga y el volumen de una cuenta representativa. Tras un cambio, esta versión envía la agenda completa con su texto y admite hasta 512 KiB de transcripción por registro. Para bibliotecas grandes, paginar la agenda y cargar el texto por reunión. Revisar cuotas por cuenta, acceso operativo, retención de backups y borrado en el proveedor antes de abrir el servicio.
