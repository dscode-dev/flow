-- Retention indexes and automatic invalidation of ephemeral session credentials.
-- +goose Up
ALTER TABLE participation.checkin_credentials DROP CONSTRAINT checkin_credentials_session_id_fkey;
ALTER TABLE participation.checkin_credentials ADD CONSTRAINT checkin_credentials_session_id_fkey
 FOREIGN KEY(session_id) REFERENCES identity.sessions(id) ON DELETE CASCADE;
CREATE INDEX participation_credential_expiry ON participation.checkin_credentials(expires_at,id);
CREATE INDEX participation_rate_retention ON participation.rate_limits(window_start,user_id);

-- +goose Down
DROP INDEX participation.participation_rate_retention;
DROP INDEX participation.participation_credential_expiry;
ALTER TABLE participation.checkin_credentials DROP CONSTRAINT checkin_credentials_session_id_fkey;
ALTER TABLE participation.checkin_credentials ADD CONSTRAINT checkin_credentials_session_id_fkey
 FOREIGN KEY(session_id) REFERENCES identity.sessions(id);
