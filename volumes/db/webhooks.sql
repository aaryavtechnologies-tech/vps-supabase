-- Supabase DB Initialization: Webhook support
-- This file is sourced from the official Supabase docker repo
-- https://github.com/supabase/supabase/tree/master/docker/volumes/db

BEGIN;

CREATE SCHEMA IF NOT EXISTS supabase_functions;
CREATE TABLE IF NOT EXISTS supabase_functions.hooks (
  id          BIGSERIAL PRIMARY KEY,
  hook_table_id INTEGER NOT NULL,
  hook_name   TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  request_id  BIGINT
);
CREATE INDEX IF NOT EXISTS supabase_functions_hooks_request_id_idx
  ON supabase_functions.hooks (request_id);

CREATE OR REPLACE FUNCTION supabase_functions.http_request()
  RETURNS TRIGGER LANGUAGE PLPGSQL AS $$
DECLARE
  request_id BIGINT;
  payload JSONB;
  url TEXT := TG_ARGV[0]::TEXT;
  method TEXT := TG_ARGV[1]::TEXT;
  headers JSONB DEFAULT '{}'::JSONB;
  params JSONB DEFAULT '{}'::JSONB;
  timeout_ms INTEGER DEFAULT 1000;
BEGIN
  IF url IS NULL OR url = 'null' THEN
    RAISE EXCEPTION 'url argument is missing';
  END IF;
  IF method IS NULL OR method = 'null' THEN
    RAISE EXCEPTION 'method argument is missing';
  END IF;
  IF TG_ARGV[2] IS NULL OR TG_ARGV[2] = 'null' THEN
    headers = '{}'::JSONB;
  ELSE
    headers = TG_ARGV[2]::JSONB;
  END IF;
  IF TG_ARGV[3] IS NULL OR TG_ARGV[3] = 'null' THEN
    params = '{}'::JSONB;
  ELSE
    params = TG_ARGV[3]::JSONB;
  END IF;
  IF TG_ARGV[4] IS NULL OR TG_ARGV[4] = 'null' THEN
    timeout_ms = 1000;
  ELSE
    timeout_ms = TG_ARGV[4]::INTEGER;
  END IF;

  CASE method
    WHEN 'GET' THEN
      SELECT net.http_get(url, params, headers, timeout_ms)
      INTO request_id;
    WHEN 'POST' THEN
      payload = jsonb_build_object(
        'old_record', OLD,
        'record', NEW,
        'type', TG_OP,
        'table', TG_TABLE_NAME,
        'schema', TG_TABLE_SCHEMA
      );
      SELECT net.http_post(url, payload, params, headers, timeout_ms)
      INTO request_id;
    ELSE
      RAISE EXCEPTION 'method argument % is invalid', method;
  END CASE;

  INSERT INTO supabase_functions.hooks
    (hook_table_id, hook_name, request_id)
  VALUES
    (TG_RELID, TG_NAME, request_id);
  RETURN NEW;
END;
$$;

COMMIT;
