-- Rend le service ml idempotent sur les recommandations, sur une base deja
-- initialisee : les scripts de db/init/ ne rejouent pas sur un volume existant.
--
-- Idempotent : peut etre rejouee sans effet si deja appliquee.
BEGIN;

ALTER TABLE recommendation ALTER COLUMN prediction_id SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'uq_recommendation_prediction'
    ) THEN
        ALTER TABLE recommendation ADD CONSTRAINT uq_recommendation_prediction
            UNIQUE (prediction_id, "timestamp");
    END IF;
END
$$;

COMMIT;
