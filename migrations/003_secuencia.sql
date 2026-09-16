-- ============================================================================
-- 003 · Máquina de estados de la secuencia comercial
-- ============================================================================
--
-- WF-02 manda UN correo y se acaba: su `Pick 1 Lead` exige
-- `last_email_sent_at IS NULL`, así que en cuanto alguien recibe el primer
-- correo ya no vuelve a salir elegido nunca. La secuencia de cinco toques del
-- plan no existía en ninguna parte.
--
-- Esto añade el estado mínimo para llevarla:
--
--   paso 0 → día 0  · correo de presentación      (lo manda WF-02)
--   paso 1 → día 3  · guía del país, con A/B      (WF-05)
--   paso 2 → día 6  · WhatsApp                    (WF-05 → cola de tareas)
--   paso 3 → día 10 · cierre                      (WF-05)
--   paso 4 → día 14 · no_respuesta + newsletter   (WF-05)
--
-- IDEMPOTENTE. Requiere 002_segmentacion.sql aplicada.
--
--     psql -U <usuario> -d <base> -f migrations/003_secuencia.sql
--
-- ============================================================================

BEGIN;

-- --- Estado de la secuencia -------------------------------------------------

ALTER TABLE leads ADD COLUMN IF NOT EXISTS secuencia_paso INT NOT NULL DEFAULT 0;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS secuencia_proximo_at TIMESTAMPTZ;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS secuencia_fin_at TIMESTAMPTZ;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS replied_at TIMESTAMPTZ;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS variante_guia TEXT;

COMMENT ON COLUMN leads.secuencia_paso IS
  '0 = solo el correo inicial · 1 = guía · 2 = WhatsApp · 3 = cierre · 4 = terminada';
COMMENT ON COLUMN leads.replied_at IS
  'Contestó. Mientras no sea NULL, la secuencia NO avanza: seguir escribiendo '
  'a quien ya respondió es peor que no escribir.';
COMMENT ON COLUMN leads.variante_guia IS
  'A = guía en la web (medible por scroll y tiempo) · B = PDF descargable';

ALTER TABLE leads DROP CONSTRAINT IF EXISTS leads_secuencia_paso_valido;
ALTER TABLE leads ADD CONSTRAINT leads_secuencia_paso_valido
  CHECK (secuencia_paso BETWEEN 0 AND 4);

ALTER TABLE leads DROP CONSTRAINT IF EXISTS leads_variante_guia_valida;
ALTER TABLE leads ADD CONSTRAINT leads_variante_guia_valida
  CHECK (variante_guia IS NULL OR variante_guia IN ('A','B'));

-- El índice que usa WF-05 en cada pasada: sólo las filas que tocan hoy.
CREATE INDEX IF NOT EXISTS leads_secuencia_pendiente_idx
  ON leads (secuencia_proximo_at)
  WHERE secuencia_proximo_at IS NOT NULL
    AND replied_at IS NULL
    AND unsubscribed_at IS NULL;

-- --- Cola de WhatsApp -------------------------------------------------------
--
-- El toque del día 6 es por WhatsApp, y el alta en WhatsApp Cloud API sigue
-- pendiente. En vez de bloquear la secuencia entera por eso, el paso deja una
-- tarea aquí: se puede trabajar a mano desde el primer día, y cuando WF-07
-- exista bastará con que la consuma. La secuencia avanza igual.

CREATE TABLE IF NOT EXISTS tareas_whatsapp (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id       UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  telefono      TEXT,
  idioma        TEXT,
  mensaje       TEXT,
  estado        TEXT NOT NULL DEFAULT 'pendiente',
  creada_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completada_at TIMESTAMPTZ,
  CONSTRAINT tareas_whatsapp_estado_valido
    CHECK (estado IN ('pendiente','enviada','sin_telefono','descartada'))
);

-- Una tarea viva por lead: si la secuencia se reejecuta, no se duplica.
CREATE UNIQUE INDEX IF NOT EXISTS tareas_whatsapp_lead_viva_idx
  ON tareas_whatsapp (lead_id) WHERE estado = 'pendiente';

-- --- Calendario de la secuencia ---------------------------------------------
-- Los días viven aquí y no repartidos por los nodos del workflow, para poder
-- cambiar la cadencia en un sitio.

CREATE OR REPLACE FUNCTION sfe_dias_hasta_paso(paso INT)
RETURNS INT
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE paso
    WHEN 1 THEN 3    -- guía
    WHEN 2 THEN 6    -- WhatsApp
    WHEN 3 THEN 10   -- cierre
    WHEN 4 THEN 14   -- no_respuesta
    ELSE NULL
  END;
$$;

-- --- Arranque de la secuencia -----------------------------------------------
-- Al mandarse el correo inicial hay que fijar cuándo toca el siguiente. WF-02
-- no lo sabe hacer, así que WF-05 recoge también a los que ya están enviados
-- pero sin fecha.

CREATE OR REPLACE FUNCTION sfe_variante_ab(lead_id UUID)
RETURNS TEXT
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  -- Determinista a partir del uuid: el mismo lead cae siempre en la misma
  -- rama aunque se recalcule, que es lo que hace comparable un A/B.
  SELECT CASE WHEN ('x' || substr(md5(lead_id::text), 1, 8))::bit(32)::int % 2 = 0
              THEN 'A' ELSE 'B' END;
$$;

-- --- Autocomprobación -------------------------------------------------------

DO $$
DECLARE
  a INT;
  b INT;
BEGIN
  IF sfe_dias_hasta_paso(1) <> 3  THEN RAISE EXCEPTION 'calendario paso 1'; END IF;
  IF sfe_dias_hasta_paso(4) <> 14 THEN RAISE EXCEPTION 'calendario paso 4'; END IF;
  IF sfe_dias_hasta_paso(9) IS NOT NULL THEN RAISE EXCEPTION 'paso inexistente'; END IF;

  -- La variante debe ser estable para el mismo uuid...
  IF sfe_variante_ab('11111111-1111-1111-1111-111111111111')
     <> sfe_variante_ab('11111111-1111-1111-1111-111111111111') THEN
    RAISE EXCEPTION 'la variante A/B no es determinista';
  END IF;

  -- ...y repartir de forma razonable. Con 1000 uuids, entre 40 % y 60 %.
  SELECT COUNT(*) FILTER (WHERE v = 'A'), COUNT(*) FILTER (WHERE v = 'B')
    INTO a, b
  FROM (SELECT sfe_variante_ab(gen_random_uuid()) AS v
        FROM generate_series(1, 1000)) t;

  IF a < 400 OR a > 600 THEN
    RAISE EXCEPTION 'reparto A/B desequilibrado: % A frente a % B', a, b;
  END IF;

  RAISE NOTICE 'Secuencia: autocomprobacion superada (reparto A/B: % / %).', a, b;
END;
$$;

COMMIT;
