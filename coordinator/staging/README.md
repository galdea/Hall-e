# Hall-e Staging

Las compilaciones privadas de macOS y Android incluyen el origen `https://halle-account-staging.gabriel-aldea.workers.dev`. Este entorno usa dos identidades sintéticas y el flujo de correo y código de la aplicación. El buzón es un Worker accesible mediante un enlace privado entre servicios. Su lectura requiere acceso administrativo a la base D1 de staging.

## Probar con dos dispositivos

1. Abre **Hall-e Staging → Agenda privada** en el Mac. Solicita el código para `halle-owner@example.test`.
2. En la terminal del Mac autenticado con Wrangler, ejecuta `node coordinator/scripts/staging-code.mjs` desde el repositorio. Introduce el código en el Mac. Caduca en diez minutos. Cada lectura consume el mensaje del buzón.
3. Repite el proceso en Android con el mismo correo. Solicita y verifica los códigos de los dispositivos de uno en uno.
4. Crea una reunión sintética en un dispositivo, asígnale un proyecto y sincroniza el otro. En Android, abre esa reunión y pulsa **Enviar tono de prueba**. Al actualizar la reunión en el Mac aparece el resultado marcado como sintético. Para comprobar el aislamiento puedes iniciar una sesión independiente como `halle-other@example.test` y consultar su código pasando ese correo al comando.

Usa solo datos de prueba. Para comprobar el recorrido de audio con el servicio alojado, la prueba automatizada sube `test-support/phone-tone.mp4`. Staging verifica los bytes guardados en R2 y devuelve un resultado marcado como sintético. Con cualquier otra grabación se indica que el proveedor está sin configurar. Las credenciales de Google, el correo de destinatarios reales y los proveedores comerciales de voz requieren una configuración independiente.

## Recursos y comprobación

La API tiene su propia configuración en `wrangler.account.staging.jsonc`, con el binding `ACCOUNT_DB` para D1 y `ACCOUNT_AUDIO` para el bucket R2 privado. El buzón usa `wrangler.account.staging-mail.jsonc`. El secreto `ACCOUNT_AUTH_SECRET` se mantiene en Cloudflare. El esquema específico del buzón está en `staging/mailbox.sql`.

El ensayo alojado usa `HALLE_STAGE_ORIGIN`, `HALLE_STAGE_CONFIG` y `WRANGLER_BIN` para ejecutar `node coordinator/scripts/account-staging-smoke.mjs`. Comprueba el acceso por código, la sincronización, el aislamiento, la repetición de una carga y la revocación de las sesiones creadas por la prueba. Para empaquetar los clientes privados se usan `HALLE_STAGING=1` y `HALLE_ACCOUNT_ORIGIN` con el origen del entorno.
