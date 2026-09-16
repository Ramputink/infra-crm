# Puesta en marcha del embudo

Guía de despliegue de las cuatro migraciones y los tres workflows nuevos. El `README.md`
describe la infraestructura; esto describe **qué ejecutar, en qué orden y qué hace falta de ti**.

Todo lo de aquí está verificado contra PostgreSQL 17, pero **nada se ha ejecutado contra tu
servidor**: no tengo acceso.

---

## 0. Antes de nada: dos cosas que bloquean todo

### El repositorio es público

Con la URL del formulario de `workflow1` publicada aquí dentro y sin autenticación en el Form
Trigger, cualquiera podía subir un `.xlsx` que acabara disparando correo real desde la cuenta
corporativa. El paso 3 lo cierra, pero **pasar el repositorio a privado** lo resuelve de golpe
y además retira de circulación tu teléfono y tu dirección, que están en las plantillas de
WF-02.

### Rotar el `webhookId` del formulario

Cerrar el acceso no cambia que el identificador actual sea público. Hay que **recrear el nodo
`On form submission`** para que n8n genere uno nuevo. Cambiar el dominio no sirve: está en DNS.

---

## 1. Migraciones, en orden

Se aplican de la 002 a la 005 y **cada una se autocomprueba**: si algo no cuadra, aborta con
un mensaje que dice qué, en vez de dejar el esquema a medias.

```bash
cd /opt/automatizacion_crm
for m in 002_segmentacion 003_secuencia 004_pagos 005_legado_sqlite; do
  docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 -f - < "migrations/${m}.sql" || break
done
```

Debe salir una línea `NOTICE: ... autocomprobacion superada.` por cada una. Son idempotentes:
volver a ejecutarlas no rompe nada.

| Migración | Qué añade |
|---|---|
| `002_segmentacion` | `embudo`, `idioma_comunicacion` y las funciones `sfe_*` que los calculan |
| `003_secuencia` | Estado de los cinco toques, cola de WhatsApp, variante A/B |
| `004_pagos` | `stripe_eventos`, estado de pago del lead |
| `005_legado_sqlite` | `legacy_sqlite_id`, para auditar la migración de `seguimiento.db` |

**Si la 002 aborta diciendo que la base no pone en mayúsculas el cirílico**, es que se creó con
locale `C` o `POSIX`. No es un aviso menor: los alias en ruso no casarían y un lead nacido en
España que declare el país en ruso entraría en el embudo comercial, es decir, se le vendería
una homologación que no necesita. Hay que recrear la base con una locale UTF-8.

---

## 2. Migrar el histórico de SQLite

`Automatismos/Mailing/seguimiento.db` guarda 543 envíos a 497 direcciones hechos entre agosto
de 2025 y enero de 2026. Sin esto, el sistema nuevo no sabe a quién se escribió ya.

```bash
cd ~/Desktop/Empresas/ROSFORD/Automatismos/Mailing
pip install psycopg2-binary
python3 migrar_seguimiento_a_postgres.py --dry-run      # mirar primero
python3 migrar_seguimiento_a_postgres.py --dsn "postgresql://..."
```

Es idempotente: una segunda pasada da 0 nuevos, 0 mensajes, 0 eventos.

El **embudo se deja vacío a propósito**. `seguimiento.db` no guarda ni país de nacimiento ni
tipo de producto, que son los dos campos que deciden; lo rellena WF-04. Inventarlo con datos
que no se tienen sería peor que dejarlo.

---

## 3. Caddy: cerrar los formularios

```bash
docker compose run --rm caddy caddy hash-password
```

Al `.env`:

```
FORM_USER=rosford
FORM_PASSWORD_HASH=$$2a$$14$$...
```

**Los `$` van duplicados.** Docker compose interpreta `$` como inicio de variable, y ese es el
error que deja el hash roto y la autenticación fallando siempre.

Validar antes de recargar:

```bash
docker compose run --rm caddy caddy validate --config /etc/caddy/Caddyfile
docker compose up -d caddy
```

**Si Caddy no arranca, mira el `.env` antes que nada.** La sustitución `{$VAR}` ocurre antes de
parsear, así que sin esas dos variables el bloque queda vacío y el servidor se niega a
levantar. Es deliberado: para un control de seguridad, mejor caído que abierto.

---

## 4. Importar los workflows

Import from File, uno por uno. Cada nodo de PostgreSQL pide credencial: asignar la que ya usan
WF-02 y `workflow1`.

### WF-04 · Segmentador

Cada 15 minutos. Clasifica en embudo e idioma, y saca de la cola a los nacidos en España.

Se puede ejecutar a mano la primera vez para ver el reparto. Sobre los datos actuales sale:

| Embudo | Leads |
|---|---|
| consulta 100 € | 415 |
| homologación 500 € | 281 |
| **solo newsletter** | **237** |
| a cualificar | 1 |

Uno de cada cuatro leads nació en España: ya tiene el título español y no hay nada que
homologar.

### WF-05 · Secuencia

Diario a las 10:00, sólo laborables. Lleva los cinco toques: día 0 correo (lo manda WF-02),
día 3 guía, día 6 WhatsApp, día 10 cierre, día 14 `no_respuesta`.

**El toque de WhatsApp no envía nada todavía**: deja una fila en `tareas_whatsapp`. Se puede
trabajar a mano desde el primer día:

```sql
SELECT l.email, l.first_name, t.telefono, t.idioma
FROM tareas_whatsapp t JOIN leads l ON l.id = t.lead_id
WHERE t.estado = 'pendiente' ORDER BY t.creada_at;
```

Al despacharlas: `UPDATE tareas_whatsapp SET estado='enviada', completada_at=NOW() WHERE id=...`.

### WF-06 · Webhook de Stripe

1. Importar; n8n genera la URL.
2. Stripe → Developers → Webhooks → apuntar a esa URL, evento `checkout.session.completed`.
3. Copiar el signing secret (`whsec_...`) a `STRIPE_WEBHOOK_SECRET` en el entorno de n8n.

**En los Payment Links hay que pasar `client_reference_id` con el uuid del lead.** Sin eso hay
ventas pero no se sabe de dónde salieron, que es justo lo que se necesita para decidir dónde
gastar.

---

## 5. Comprobar que el embudo respira

```sql
-- Reparto por embudo y estado
SELECT embudo, email_status, count(*) FROM leads GROUP BY 1,2 ORDER BY 3 DESC;

-- Dónde se cae la gente
SELECT secuencia_paso, count(*) FROM leads
WHERE secuencia_proximo_at IS NOT NULL GROUP BY 1 ORDER BY 1;

-- A/B de las guías: lo que importa no es el clic, es la conversión a pago
SELECT variante_guia,
       count(*) AS leads,
       count(*) FILTER (WHERE pagado_at IS NOT NULL) AS pagaron
FROM leads WHERE variante_guia IS NOT NULL GROUP BY 1;

-- Ingresos
SELECT producto, count(*), sum(importe_cent)/100.0 AS eur
FROM leads WHERE pagado_at IS NOT NULL GROUP BY 1;
```

---

## Lo que sigue sin poder hacerse

| Qué | Por qué |
|---|---|
| **WF-07 Entrada WhatsApp** | Sin alta en WhatsApp Cloud API no hay webhook al que suscribirse. Mientras tanto, la cola de tareas cubre el hueco a mano |
| **Enviar la campaña** | Falta `UNSUBSCRIBE_SECRET` en el `.env` del mailer. Sin él no sale ni un correo, a propósito |
| **Rotar la contraseña SMTP** | Estuvo en `env.example`, un fichero pensado para compartirse |

---

## Un apunte sobre WF-02

El nodo `RETESTERErrase before launch` está ahora **desactivado**. Borraba la fila de
`worker_locks` en cada disparo del cron, justo antes de adquirir el lock, lo que anulaba la
exclusión mutua: dos workers podían enviar a la vez. Además reponía una dirección de pruebas a
la cola cada dos minutos — 390 correos al día a la misma persona.

Se conserva el nodo porque para re-testear hace falta. **Reactivar sólo a mano, y volver a
apagarlo después.**
