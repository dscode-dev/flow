-- +goose Up
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA integration;
CREATE TABLE integration.outbox (
 event_id uuid PRIMARY KEY,
 event_type text NOT NULL CHECK (length(event_type) BETWEEN 1 AND 150),
 schema_version integer NOT NULL CHECK (schema_version > 0),
 aggregate_id uuid NOT NULL,
 occurred_at timestamptz NOT NULL,
 payload jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 published_at timestamptz
);
CREATE INDEX outbox_pending ON integration.outbox (created_at, event_id) WHERE published_at IS NULL;
CREATE TABLE integration.inbox (
 consumer text NOT NULL,
 event_id uuid NOT NULL,
 processed_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY (consumer, event_id)
);

-- +goose Down
DROP TABLE integration.inbox;
DROP TABLE integration.outbox;
DROP SCHEMA integration;
-- PostGIS é uma extensão compartilhada. Rollback não remove a extensão.
