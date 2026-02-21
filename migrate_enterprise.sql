-- ============================================================
-- migrate_enterprise.sql
-- WF-02 ColdEmailSender — tablas de soporte
-- Ejecutar ANTES de importar workflow2.json
-- Uso: psql -U crm_user -d crm -f migrate_enterprise.sql
-- ============================================================

-- 1) ALTER TABLE leads — columnas adicionales para WF2
-- ============================================================

ALTER TABLE leads ADD COLUMN IF NOT EXISTS unsubscribed_at  timestamptz NULL;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS suppressed_reason text        NULL;

-- 2) email_messages — persistencia + idempotencia de envíos
-- ============================================================

CREATE TABLE IF NOT EXISTS email_messages (
    id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id          UUID         NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
    campaign_type    text         NOT NULL DEFAULT 'cold_email',
    subject          text         NOT NULL,
    body_html        text         NOT NULL,
    body_text        text,
    status           text         NOT NULL DEFAULT 'sending',
    provider         text                  DEFAULT 'smtp',
    error_message    text,
    retry_count      int          NOT NULL DEFAULT 0,
    idempotency_key  text,
    created_at       timestamptz  NOT NULL DEFAULT now(),
    updated_at       timestamptz  NOT NULL DEFAULT now(),
    sent_at          timestamptz,

    CONSTRAINT uq_email_messages_lead_campaign
        UNIQUE (lead_id, campaign_type)
);

-- Partial unique on idempotency_key (non-null only)
CREATE UNIQUE INDEX IF NOT EXISTS idx_email_messages_idempotency
    ON email_messages (idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- Lookup by status + age
CREATE INDEX IF NOT EXISTS idx_email_messages_status_created
    ON email_messages (status, created_at);

-- Lookup by lead
CREATE INDEX IF NOT EXISTS idx_email_messages_lead_id
    ON email_messages (lead_id);

-- 3) worker_locks — lock distribuido (un solo worker activo)
-- ============================================================

CREATE TABLE IF NOT EXISTS worker_locks (
    lock_key      text         PRIMARY KEY,
    owner_id      text         NOT NULL,
    heartbeat_at  timestamptz  NOT NULL DEFAULT now(),
    created_at    timestamptz  NOT NULL DEFAULT now(),
    updated_at    timestamptz  NOT NULL DEFAULT now()
);

-- 4) email_events — audit trail
-- ============================================================

CREATE TABLE IF NOT EXISTS email_events (
    id                 UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    email_message_id   UUID         REFERENCES email_messages(id) ON DELETE SET NULL,
    lead_id            UUID         REFERENCES leads(id) ON DELETE SET NULL,
    event_type         text         NOT NULL,
    detail             jsonb        NOT NULL DEFAULT '{}',
    created_at         timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_email_events_message
    ON email_events (email_message_id);

CREATE INDEX IF NOT EXISTS idx_email_events_lead
    ON email_events (lead_id);

-- ============================================================
-- FIN
-- ============================================================
