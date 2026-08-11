-- Supabase DB Initialization: JWT secret
-- Installs the JWT secret into the database for use by pg_jwt extension

BEGIN;

-- Install pgjwt extension (provided by supabase/postgres image)
CREATE EXTENSION IF NOT EXISTS pgjwt WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- Store JWT settings as DB settings accessible to PostgREST
ALTER DATABASE postgres SET "app.settings.jwt_secret" TO 'PLACEHOLDER_REPLACED_BY_ENV';
ALTER DATABASE postgres SET "app.settings.jwt_exp" TO '3600';

COMMIT;
