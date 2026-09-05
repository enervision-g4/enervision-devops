-- Rend le service ml idempotent sur une base deja initialisee : les scripts de
-- db/init/ ne rejouent pas sur un volume existant, cette migration porte donc le
-- meme changement que 002_create_tables.sql pour les environnements deployes avant
-- l'introduction du service ml.
--
-- Idempotent : peut etre rejouee sans effet si deja appliquee.
BEGIN;

ALTER TABLE prediction ALTER COLUMN target_timestamp SET NOT NULL;
ALTER TABLE prediction ALTER COLUMN model_version SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'uq_prediction_site_target_model'
    ) THEN
        ALTER TABLE prediction ADD CONSTRAINT uq_prediction_site_target_model
            UNIQUE (site_id, target_timestamp, model_version, "timestamp");
    END IF;
END
$$;

COMMIT;
