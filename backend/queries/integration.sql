-- name: AppendOutbox :exec
INSERT INTO integration.outbox (event_id, event_type, schema_version, aggregate_id, occurred_at, payload)
VALUES ($1, $2, $3, $4, $5, $6);

-- name: RegisterInbox :one
INSERT INTO integration.inbox (consumer, event_id)
VALUES ($1, $2)
ON CONFLICT DO NOTHING
RETURNING event_id;
