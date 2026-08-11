-- Supabase DB Initialization: Logging schema (for Logflare/Analytics)

BEGIN;

CREATE SCHEMA IF NOT EXISTS _analytics;

COMMIT;
