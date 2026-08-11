-- Supabase DB Initialization: Roles
-- Sets up the standard Supabase database roles

BEGIN;

-- Supabase super admin
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    CREATE ROLE supabase_admin;
  END IF;
END
$$;

ALTER ROLE supabase_admin WITH
  SUPERUSER
  LOGIN
  REPLICATION
  BYPASSRLS;

-- authenticator role (used by PostgREST)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator;
  END IF;
END
$$;

ALTER ROLE authenticator WITH
  NOINHERIT
  LOGIN
  NOREPLICATION
  NOBYPASSRLS;

-- anon role (for unauthenticated requests)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon;
  END IF;
END
$$;

GRANT anon TO authenticator;

-- authenticated role (for authenticated users)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated;
  END IF;
END
$$;

GRANT authenticated TO authenticator;

-- service_role (bypasses RLS — used by backend services)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role;
  END IF;
END
$$;

ALTER ROLE service_role WITH BYPASSRLS;
GRANT service_role TO authenticator;

-- supabase_auth_admin (used by GoTrue)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin;
  END IF;
END
$$;

ALTER ROLE supabase_auth_admin WITH
  NOINHERIT
  LOGIN
  NOBYPASSRLS;

-- supabase_storage_admin (used by Storage)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
    CREATE ROLE supabase_storage_admin;
  END IF;
END
$$;

ALTER ROLE supabase_storage_admin WITH
  NOINHERIT
  LOGIN
  NOBYPASSRLS;

-- dashboard_user (used by Studio)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dashboard_user') THEN
    CREATE ROLE dashboard_user;
  END IF;
END
$$;

GRANT dashboard_user TO supabase_admin;

COMMIT;
