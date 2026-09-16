-- ============================================================================
-- 005 · Trazabilidad del legado de SQLite
-- ============================================================================
--
-- `Automatismos/Mailing/seguimiento.db` guarda 543 envíos a 497 direcciones,
-- hechos entre agosto de 2025 y enero de 2026. Al pasarlos a PostgreSQL hay
-- que poder responder «¿de dónde salió esta fila?» sin adivinar.
--
-- El script de migración ya escribía en `legacy_sqlite_id`, pero la columna
-- NO EXISTÍA: habría fallado en la primera fila.
--
-- IDEMPOTENTE. Requiere 004_pagos.sql aplicada.
--
--     psql -U <usuario> -d <base> -f migrations/005_legado_sqlite.sql
--
-- ============================================================================

BEGIN;

ALTER TABLE leads ADD COLUMN IF NOT EXISTS legacy_sqlite_id BIGINT;

COMMENT ON COLUMN leads.legacy_sqlite_id IS
  'id de la fila original en seguimiento.db. Permite auditar la migración y '
  'volver a la fuente si un dato no cuadra.';

-- Parcial: la inmensa mayoría de leads no vienen del legado, y un índice sobre
-- una columna casi toda NULL es espacio gastado en nada.
CREATE INDEX IF NOT EXISTS leads_legacy_sqlite_idx
  ON leads (legacy_sqlite_id) WHERE legacy_sqlite_id IS NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'leads' AND column_name = 'legacy_sqlite_id'
  ) THEN
    RAISE EXCEPTION 'legacy_sqlite_id no se creo';
  END IF;
  RAISE NOTICE 'Legado SQLite: autocomprobacion superada.';
END;
$$;

COMMIT;
