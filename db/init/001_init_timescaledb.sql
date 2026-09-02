-- Exécuté automatiquement au tout premier démarrage du service "db"
-- (volume g4_db_data vide). À faire évoluer via un outil de migration
-- pour la suite plutôt qu'en modifiant ce fichier après coup.

CREATE EXTENSION IF NOT EXISTS timescaledb;
