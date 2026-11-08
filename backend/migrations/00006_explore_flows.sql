-- +goose Up
CREATE EXTENSION IF NOT EXISTS unaccent;
-- +goose StatementBegin
CREATE FUNCTION experiences.search_normalize(text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $$ SELECT public.unaccent('public.unaccent', $1) $$;
-- +goose StatementEnd
ALTER TABLE experiences.experiences ADD COLUMN search_vector tsvector GENERATED ALWAYS AS
 (to_tsvector('portuguese'::regconfig,experiences.search_normalize(title || ' ' || description))) STORED;
CREATE INDEX experiences_public_search ON experiences.experiences USING gin(search_vector)
 WHERE status='PUBLISHED' AND visibility='PUBLIC' AND moderation_status='VISIBLE';

CREATE TABLE media.flow_assets (
 id uuid PRIMARY KEY, experience_id uuid NOT NULL REFERENCES experiences.experiences(id), owner_user_id uuid NOT NULL,
 idempotency_key uuid NOT NULL, request_hash bytea NOT NULL CHECK(octet_length(request_hash)=32),
 content_type text NOT NULL CHECK(content_type IN ('image/jpeg','image/png','video/mp4','video/quicktime')),
 size_bytes bigint NOT NULL CHECK(size_bytes BETWEEN 1 AND 33554432),
 status text NOT NULL DEFAULT 'UPLOADING' CHECK(status IN ('UPLOADING','PROCESSING','READY','FAILED','DELETED')),
 staging_key text NOT NULL UNIQUE, object_key text NOT NULL UNIQUE, poster_key text NOT NULL UNIQUE,
 width integer, height integer, duration_ms integer, verified_size bigint, sha256 text,
 failure_code text CHECK(failure_code IN ('invalid_media','processing_failed','expired')),
 expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), confirmed_at timestamptz,
 lease_until timestamptz, lease_id uuid, attempts integer NOT NULL DEFAULT 0,
 processed_at timestamptz, staging_cleaned_at timestamptz, deleted_at timestamptz,
 UNIQUE(owner_user_id,idempotency_key),
 CHECK(status<>'READY' OR (width BETWEEN 1 AND 4096 AND height BETWEEN 1 AND 4096 AND verified_size BETWEEN 1 AND 33554432 AND sha256 IS NOT NULL AND processed_at IS NOT NULL)),
 CHECK(duration_ms IS NULL OR duration_ms BETWEEN 1 AND 15000)
);
CREATE INDEX flow_assets_work ON media.flow_assets(status,lease_until,created_at);
CREATE INDEX flow_assets_experience ON media.flow_assets(experience_id,created_at);
CREATE TABLE experiences.flow_presentations (
 experience_id uuid PRIMARY KEY REFERENCES experiences.experiences(id),
 enabled boolean NOT NULL DEFAULT true,
 unlisted_consent_at timestamptz, unlisted_consent_actor uuid,
 image_asset_id uuid REFERENCES media.flow_assets(id), video_asset_id uuid REFERENCES media.flow_assets(id),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0), updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK((unlisted_consent_at IS NULL)=(unlisted_consent_actor IS NULL))
);
CREATE TABLE experiences.flow_audit (
 id uuid PRIMARY KEY,experience_id uuid NOT NULL,actor_user_id uuid NOT NULL,
 action text NOT NULL,version bigint NOT NULL,request_id text NOT NULL,details jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX flow_audit_time ON experiences.flow_audit(created_at);
-- No backfill: existing UNLISTED rows receive no new discoverability.
CREATE VIEW experiences.flow_discovery AS
 SELECT d.*, coalesce(p.version,0) AS presentation_version,
 i.id AS image_asset_id, v.id AS video_asset_id,
 CASE WHEN i.id IS NOT NULL THEN 'image' WHEN v.id IS NOT NULL THEN 'poster' ELSE 'cover' END AS image_kind,
 v.duration_ms, coalesce(v.width,i.width,c.width) AS media_width,coalesce(v.height,i.height,c.height) AS media_height
 FROM experiences.documents d
 JOIN identity.users u ON u.id=d.creator_user_id AND u.status='active'
 LEFT JOIN experiences.flow_presentations p ON p.experience_id=d.id
 LEFT JOIN media.flow_assets i ON i.id=p.image_asset_id AND i.status='READY' AND i.content_type LIKE 'image/%' AND i.experience_id=d.id
 LEFT JOIN media.flow_assets v ON v.id=p.video_asset_id AND v.status='READY' AND v.content_type LIKE 'video/%' AND v.experience_id=d.id
 LEFT JOIN media.uploads c ON c.id=(d.document->>'cover_media_id')::uuid AND c.status='READY'
 WHERE d.status='PUBLISHED' AND d.moderation_status='VISIBLE'
 AND coalesce(p.enabled,true)
 AND (d.visibility='PUBLIC' OR (d.visibility='UNLISTED' AND p.unlisted_consent_at IS NOT NULL))
 AND NOT EXISTS(SELECT FROM experiences.publishing_restrictions r WHERE r.creator_user_id=d.creator_user_id AND r.blocked_until>now())
 AND (i.id IS NOT NULL OR v.id IS NOT NULL OR c.id IS NOT NULL);

-- +goose Down
DROP VIEW experiences.flow_discovery;
DROP TABLE experiences.flow_audit;
DROP TABLE experiences.flow_presentations;
DROP TABLE media.flow_assets;
DROP INDEX experiences.experiences_public_search;
ALTER TABLE experiences.experiences DROP COLUMN search_vector;
DROP FUNCTION experiences.search_normalize(text);
-- unaccent may be shared; do not remove the extension.
