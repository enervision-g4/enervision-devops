-- Création des tables métier, exécuté après 001_init_timescaledb.sql
-- (l'extension timescaledb doit déjà être active).
--
-- Basé sur le MCD (Ressources/mcd-projet-piscine.png) : 7 entités.
-- Les tables de séries temporelles (mesures, alertes, prédictions,
-- recommandations) sont converties en hypertables TimescaleDB, partitionnées
-- sur leur colonne "timestamp". TimescaleDB impose que la clé primaire d'une
-- hypertable inclue la colonne de partitionnement : on utilise donc des PK
-- composites (id, timestamp) plutôt qu'une PK simple sur l'id.
--
-- Limite connue : TimescaleDB ne supporte pas de contrainte FOREIGN KEY
-- classique entre deux hypertables (car la table référencée doit avoir une
-- contrainte UNIQUE sur la seule colonne id, ce qu'une hypertable ne peut
-- pas garantir). Les liens measure_imputed -> measure_raw et
-- recommendation -> prediction sont donc simplement indexés, pas contraints
-- par FK. Les FK vers "site" (table normale, non-hypertable) restent de
-- vraies contraintes.
--
-- Idempotence de l'ingestion : les consumers Kafka reçoivent chaque message au
-- moins une fois, et l'API source n'est pas déterministe (deux appels sur le même
-- horodatage renvoient des valeurs différentes). Les tables alimentées par le flux
-- portent donc une contrainte d'unicité métier, sur laquelle le consumer s'appuie
-- via ON CONFLICT DO NOTHING pour que la première écriture gagne : (site_id,
-- timestamp) pour les mesures, source_alert_id pour les alertes. Une hypertable
-- exigeant que toute contrainte unique inclue sa colonne de partitionnement,
-- "timestamp" figure dans chacune d'elles.

-- ============================================================
-- SITE (table de référence, pas une hypertable)
-- ============================================================
CREATE TABLE IF NOT EXISTS site (
    site_id      TEXT PRIMARY KEY,
    site_type    TEXT NOT NULL,
    site_name    TEXT NOT NULL,
    location     TEXT,
    capacity_kw  INTEGER,
    status       TEXT
);

-- ============================================================
-- MEASURE_RAW
-- ============================================================
CREATE TABLE IF NOT EXISTS measure_raw (
    measure_raw_id       UUID NOT NULL DEFAULT gen_random_uuid(),
    "timestamp"          TIMESTAMPTZ NOT NULL,
    site_id              TEXT NOT NULL REFERENCES site (site_id),
    consumption_kw       DOUBLE PRECISION,
    consumption_kwh      DOUBLE PRECISION,
    voltage_v            DOUBLE PRECISION,
    current_a            DOUBLE PRECISION,
    power_factor         DOUBLE PRECISION,
    temperature_celsius  DOUBLE PRECISION,
    humidity_percent     DOUBLE PRECISION,
    null_reasons         TEXT[],
    data_quality         TEXT,
    PRIMARY KEY (measure_raw_id, "timestamp"),
    CONSTRAINT uq_measure_raw_site_timestamp UNIQUE (site_id, "timestamp")
);

SELECT create_hypertable(
    'measure_raw', 'timestamp',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_measure_raw_site_time
    ON measure_raw (site_id, "timestamp" DESC);

-- ============================================================
-- MEASURE_IMPUTED
-- ============================================================
CREATE TABLE IF NOT EXISTS measure_imputed (
    measure_imputed_id   UUID NOT NULL DEFAULT gen_random_uuid(),
    measure_raw_id       UUID,
    site_id              TEXT NOT NULL REFERENCES site (site_id),
    "timestamp"          TIMESTAMPTZ NOT NULL,
    consumption_kw       DOUBLE PRECISION,
    consumption_kwh      DOUBLE PRECISION,
    voltage_v            DOUBLE PRECISION,
    current_a            DOUBLE PRECISION,
    power_factor         DOUBLE PRECISION,
    temperature_celsius  DOUBLE PRECISION,
    humidity_percent     DOUBLE PRECISION,
    imputation_method    TEXT,
    PRIMARY KEY (measure_imputed_id, "timestamp"),
    CONSTRAINT uq_measure_imputed_site_timestamp UNIQUE (site_id, "timestamp")
);

SELECT create_hypertable(
    'measure_imputed', 'timestamp',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_measure_imputed_site_time
    ON measure_imputed (site_id, "timestamp" DESC);
CREATE INDEX IF NOT EXISTS idx_measure_imputed_raw_id
    ON measure_imputed (measure_raw_id);

-- ============================================================
-- ALERT
-- ============================================================
CREATE TABLE IF NOT EXISTS alert (
    alert_id         UUID NOT NULL DEFAULT gen_random_uuid(),
    -- Identifiant attribué par l'API source (ex. ALR-SITE002-1718458320). Il porte
    -- l'idempotence : la contrainte ci-dessous absorbe la remise d'un même message par
    -- Kafka sans dupliquer la ligne, au même titre que pour les mesures. alert_id
    -- reste la clé technique, attendue en UUID par enervision-api.
    --
    -- Mesuré sur l'instance mock : elle fabrique une liste d'alertes neuve à chaque
    -- appel plutôt que de renvoyer des alertes actives durables, deux interrogations
    -- espacées de vingt secondes n'ayant aucune alerte en commun. Cette contrainte ne
    -- dédoublonne donc rien à la source, et la table accumule autant d'alertes que le
    -- collecteur en relève. C'est une propriété du simulateur, pas du schéma.
    source_alert_id  TEXT NOT NULL,
    "timestamp"      TIMESTAMPTZ NOT NULL,
    site_id          TEXT NOT NULL REFERENCES site (site_id),
    severity         TEXT,
    type             TEXT,
    message          TEXT,
    value_kw         DOUBLE PRECISION,
    threshold_kw     DOUBLE PRECISION,
    PRIMARY KEY (alert_id, "timestamp"),
    CONSTRAINT uq_alert_source_alert_id UNIQUE (source_alert_id, "timestamp")
);

SELECT create_hypertable(
    'alert', 'timestamp',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_alert_site_time
    ON alert (site_id, "timestamp" DESC);

-- ============================================================
-- PREDICTION
-- ============================================================
CREATE TABLE IF NOT EXISTS prediction (
    prediction_id             UUID NOT NULL DEFAULT gen_random_uuid(),
    site_id                   TEXT NOT NULL REFERENCES site (site_id),
    target_timestamp          TIMESTAMPTZ,
    predicted_consumption_kw  DOUBLE PRECISION,
    threshold_kw              DOUBLE PRECISION,
    model_version             TEXT,
    "timestamp"               TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (prediction_id, "timestamp")
);

SELECT create_hypertable(
    'prediction', 'timestamp',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_prediction_site_time
    ON prediction (site_id, "timestamp" DESC);

-- ============================================================
-- RECOMMENDATION
-- ============================================================
CREATE TABLE IF NOT EXISTS recommendation (
    recommendation_id   UUID NOT NULL DEFAULT gen_random_uuid(),
    site_id             TEXT NOT NULL REFERENCES site (site_id),
    prediction_id       UUID,
    "timestamp"         TIMESTAMPTZ NOT NULL,
    action_description  TEXT,
    status              TEXT,
    PRIMARY KEY (recommendation_id, "timestamp")
);

SELECT create_hypertable(
    'recommendation', 'timestamp',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_recommendation_site_time
    ON recommendation (site_id, "timestamp" DESC);
CREATE INDEX IF NOT EXISTS idx_recommendation_prediction_id
    ON recommendation (prediction_id);
