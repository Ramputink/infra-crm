-- ============================================================================
-- 004 · Pagos de Stripe
-- ============================================================================
--
-- Registra los cobros y los ata al lead que los produjo.
--
-- LA PIEZA QUE LO HACE ATRIBUIBLE
-- -------------------------------
-- El Payment Link lleva `client_reference_id` con el uuid del lead. Stripe lo
-- devuelve tal cual en `checkout.session.completed`, y es lo único que permite
-- responder «este ingreso vino de aquel correo». Sin eso hay ventas, pero no
-- se sabe de dónde salieron y no se puede decidir en qué gastar.
--
-- IDEMPOTENTE. Requiere 003_secuencia.sql aplicada.
--
--     psql -U <usuario> -d <base> -f migrations/004_pagos.sql
--
-- ============================================================================

BEGIN;

-- --- Eventos recibidos de Stripe --------------------------------------------
--
-- Stripe REINTENTA los webhooks: el mismo evento llega varias veces si la
-- primera respuesta tarda o falla. Sin una clave única por `event_id` se
-- contaría el mismo cobro dos veces y la facturación quedaría inflada.
-- La unicidad la pone la base, no el workflow.

CREATE TABLE IF NOT EXISTS stripe_eventos (
  event_id     TEXT PRIMARY KEY,
  tipo         TEXT NOT NULL,
  lead_id      UUID REFERENCES leads(id) ON DELETE SET NULL,
  importe_cent BIGINT,
  moneda       TEXT,
  email_pago   TEXT,
  payload      JSONB NOT NULL,
  recibido_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS stripe_eventos_lead_idx ON stripe_eventos (lead_id);
CREATE INDEX IF NOT EXISTS stripe_eventos_fecha_idx ON stripe_eventos (recibido_at DESC);

COMMENT ON TABLE stripe_eventos IS
  'Cada webhook de Stripe, tal cual llegó. event_id es PRIMARY KEY porque '
  'Stripe reintenta y sin eso el mismo cobro se contaría varias veces.';

-- --- Estado de pago del lead ------------------------------------------------

ALTER TABLE leads ADD COLUMN IF NOT EXISTS pagado_at    TIMESTAMPTZ;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS importe_cent BIGINT;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS producto     TEXT;

COMMENT ON COLUMN leads.producto IS
  'consulta_100 o homologacion_500. Se deduce del importe cobrado, no de lo '
  'que se le ofrecio: lo que cuenta es lo que acabo comprando.';

ALTER TABLE leads DROP CONSTRAINT IF EXISTS leads_producto_valido;
ALTER TABLE leads ADD CONSTRAINT leads_producto_valido
  CHECK (producto IS NULL OR producto IN ('consulta_100','homologacion_500','otro'));

-- --- Deducir el producto a partir del importe -------------------------------
--
-- Los dos precios llevan IVA incluido. Se usa un margen de 50 céntimos por si
-- Stripe aplica algún redondeo, pero no más: confundir una consulta con una
-- homologación falsearía el embudo entero.

CREATE OR REPLACE FUNCTION sfe_producto_por_importe(importe_cent BIGINT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN importe_cent IS NULL             THEN NULL
    WHEN importe_cent BETWEEN  9950 AND 10050 THEN 'consulta_100'
    WHEN importe_cent BETWEEN 49950 AND 50050 THEN 'homologacion_500'
    ELSE 'otro'
  END;
$$;

-- --- Autocomprobación -------------------------------------------------------

DO $$
BEGIN
  IF sfe_producto_por_importe(10000) <> 'consulta_100'      THEN RAISE EXCEPTION '100 EUR'; END IF;
  IF sfe_producto_por_importe(50000) <> 'homologacion_500'  THEN RAISE EXCEPTION '500 EUR'; END IF;
  IF sfe_producto_por_importe(40000) <> 'otro'              THEN RAISE EXCEPTION 'importe raro'; END IF;
  IF sfe_producto_por_importe(NULL)  IS NOT NULL            THEN RAISE EXCEPTION 'NULL'; END IF;

  -- 400 EUR es el resto de la ruta consulta -> homologacion. Debe quedar como
  -- 'otro' y no confundirse con ninguno de los dos productos.
  IF sfe_producto_por_importe(40000) = 'homologacion_500' THEN
    RAISE EXCEPTION 'el resto de 400 EUR no puede contarse como homologacion completa';
  END IF;

  RAISE NOTICE 'Pagos: autocomprobacion superada.';
END;
$$;

COMMIT;
