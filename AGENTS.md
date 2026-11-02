# HuntAlgNet - Reglas permanentes del proyecto

## Idioma (obligatorio, sin excepciones)

- El sitio soporta exactamente 10 idiomas:
  - `en-US` Inglés americano (idioma por defecto)
  - `es-ES` Español
  - `fr-FR` Francés
  - `it-IT` Italiano
  - `de-DE` Alemán
  - `zh-CN` Chino
  - `ja-JP` Japonés
  - `pt-PT` Portugués
  - `ar-SA` Árabe (RTL)
  - `ru-RU` Ruso
- TODAS las vistas, componentes, mensajes, validaciones, errores visibles, emails,
  notificaciones, textos de ayuda y contenido de interfaz deben estar traducidos a los
  10 idiomas. No se permite texto hardcodeado en ninguna vista.
- Nunca se añade una vista, componente o mensaje sin sus 10 traducciones al mismo tiempo.
- Los catálogos viven en `app/locales/<locale>.json`. Toda clave nueva debe añadirse a
  los 10 archivos en el mismo cambio.
- Sin sesión: se detecta el idioma del navegador (`Accept-Language` / `navigator.languages`),
  se usa el primer idioma soportado y, si no hay coincidencia, `en-US`.
- Con sesión: se usa el `locale` guardado del usuario; si no existe, el del navegador;
  fallback final `en-US`.
- El árabe siempre se renderiza con `dir="rtl"`; el resto con `dir="ltr"`.
- Fechas, números, monedas y plurales deben formatearse con el locale activo.
- El backend expone los catalogos en `/api/v1/i18n/{locale}` y el cliente en `web/i18n.js`.
- La suite de tests debe fallar si falta una clave o una traduccion en cualquiera de los
  10 idiomas.

## Arquitectura

- Backend Python/FastAPI con PostgreSQL, Redis y Celery.
- IA local gratuita mediante Ollama en el servidor.
- Despliegue nativo en Ubuntu/Debian con systemd y Nginx.
- NO usar Docker en este proyecto.
- Multi-tenant: organizaciones, usuarios y roles (`owner`, `admin`, `editor`, `analyst`, `viewer`).

## Instalador (obligatorio)

- `deploy/install.sh` debe instalar y configurar TODAS las dependencias de sistema,
  servicios, paquetes y utilidades que la aplicacion necesite (PostgreSQL, Redis, Nginx,
  Ollama, GPG, logrotate, firewall, fail2ban, TLS, sincronizacion horaria, etc.).
- Cada vez que se anada una nueva dependencia, servicio o programa al proyecto, se debe
  anadir en el mismo cambio su instalacion y configuracion completa en `deploy/install.sh`
  (y en `deploy/update.sh` si afecta a actualizaciones).
- El instalador debe verificar que los comandos y servicios requeridos existen y estan
  activos antes de finalizar, y debe ser idempotente.

## Seguridad

- Secretos solo en `.env` con permisos `600`, nunca en el repositorio.
- Tokens OAuth de redes sociales cifrados en reposo.
- TLS obligatorio, cabeceras de seguridad, rate limiting, firewall y fail2ban.
- Backups cifrados y con retencion.
