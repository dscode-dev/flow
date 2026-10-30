-- +goose Up
CREATE SCHEMA media;
CREATE TABLE media.uploads (
 id uuid PRIMARY KEY,
 owner_user_id uuid NOT NULL,
 idempotency_key uuid NOT NULL,
 request_hash bytea NOT NULL CHECK(octet_length(request_hash)=32),
 status text NOT NULL DEFAULT 'UPLOADING' CHECK(status IN ('UPLOADING','READY','REJECTED','DELETED')),
 content_type text NOT NULL CHECK(content_type IN ('image/jpeg','image/png')),
 size_bytes bigint NOT NULL CHECK(size_bytes BETWEEN 1 AND 5242880),
 staging_key text NOT NULL UNIQUE,
 object_key text NOT NULL UNIQUE,
 verified_size bigint,
 width integer,
 height integer,
 sha256 text,
 expires_at timestamptz NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 confirmed_at timestamptz,
 staging_cleaned_at timestamptz,
 deleted_at timestamptz,
 UNIQUE(owner_user_id,idempotency_key),
 CHECK(status<>'READY' OR (confirmed_at IS NOT NULL AND verified_size IS NOT NULL AND verified_size BETWEEN 1 AND 5242880 AND width IS NOT NULL AND height IS NOT NULL AND sha256 IS NOT NULL AND width BETWEEN 1 AND 4096 AND height BETWEEN 1 AND 4096 AND width::bigint*height<=12000000 AND sha256 ~ '^[a-f0-9]{64}$'))
);
CREATE INDEX media_cleanup ON media.uploads(expires_at,id);
CREATE TABLE media.bindings (
 experience_id uuid PRIMARY KEY,
 media_id uuid NOT NULL REFERENCES media.uploads(id),
 owner_user_id uuid NOT NULL,
 bound_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX media_binding_object ON media.bindings(media_id);
CREATE TABLE media.audit_events (
 id uuid PRIMARY KEY, media_id uuid NOT NULL, actor_user_id uuid NOT NULL,
 action text NOT NULL, request_id text NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX media_audit_time ON media.audit_events(created_at);
CREATE TABLE media.rate_limits (
 owner_user_id uuid NOT NULL, window_start timestamptz NOT NULL, count integer NOT NULL CHECK(count>0),
 PRIMARY KEY(owner_user_id,window_start)
);

CREATE SCHEMA experiences;
CREATE TABLE experiences.categories (
 id text PRIMARY KEY CHECK(id ~ '^[a-z][a-z0-9_]{1,39}$'),
 name text NOT NULL CHECK(char_length(name) BETWEEN 1 AND 80),
 enabled boolean NOT NULL DEFAULT true,
 sort_order integer NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO experiences.categories(id,name,sort_order) VALUES
 ('music','Música',10),('party','Festas',20),('culture','Cultura',30),
 ('sport','Esportes',40),('gastronomy','Gastronomia',50),('nature','Natureza',60),
 ('tech','Tecnologia',70),('education','Educação',80),('community','Comunidade e encontros',90);
CREATE TABLE experiences.experiences (
 id uuid PRIMARY KEY,
 creator_user_id uuid NOT NULL,
 title text NOT NULL DEFAULT '' CHECK(char_length(title)<=120),
 description text NOT NULL DEFAULT '' CHECK(char_length(description)<=5000),
 category_id text REFERENCES experiences.categories(id),
 visibility text NOT NULL DEFAULT 'PRIVATE' CHECK(visibility IN ('PUBLIC','UNLISTED','PRIVATE')),
 status text NOT NULL DEFAULT 'DRAFT' CHECK(status IN ('DRAFT','PUBLISHED','CANCELLED','ARCHIVED')),
 moderation_status text NOT NULL DEFAULT 'VISIBLE' CHECK(moderation_status IN ('VISIBLE','WITHHELD')),
 starts_at timestamptz,
 ends_at timestamptz,
 timezone text,
 location_type text NOT NULL DEFAULT 'PHYSICAL' CHECK(location_type='PHYSICAL'),
 point geography(Point,4326),
 venue_name text NOT NULL DEFAULT '' CHECK(char_length(venue_name)<=160),
 address text NOT NULL DEFAULT '' CHECK(char_length(address)<=300),
 capacity integer CHECK(capacity BETWEEN 1 AND 1000000),
 external_ticket_url text CHECK(char_length(external_ticket_url)<=2048 AND external_ticket_url ~ '^https://'),
 cover_media_id uuid REFERENCES media.uploads(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 published_at timestamptz,
 cancelled_at timestamptz,
 archived_at timestamptz,
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 CHECK(ends_at IS NULL OR starts_at IS NULL OR (ends_at>starts_at AND ends_at-starts_at<=interval '744 hours')),
 CHECK(timezone IS NULL OR char_length(timezone) BETWEEN 1 AND 100),
 CHECK(published_at IS NULL OR (char_length(btrim(title))>=3 AND char_length(btrim(description))>=10 AND category_id IS NOT NULL AND starts_at IS NOT NULL AND ends_at IS NOT NULL AND timezone IS NOT NULL AND point IS NOT NULL AND char_length(btrim(venue_name))>=2)),
 CHECK((status='PUBLISHED' AND published_at IS NOT NULL AND cancelled_at IS NULL AND archived_at IS NULL)
    OR (status='DRAFT' AND published_at IS NULL AND cancelled_at IS NULL AND archived_at IS NULL)
    OR (status='CANCELLED' AND cancelled_at IS NOT NULL AND archived_at IS NULL)
    OR (status='ARCHIVED' AND archived_at IS NOT NULL))
);
ALTER TABLE media.bindings ADD CONSTRAINT media_binding_experience FOREIGN KEY(experience_id) REFERENCES experiences.experiences(id);
CREATE INDEX experiences_creator_page ON experiences.experiences(creator_user_id,created_at DESC,id DESC);
CREATE INDEX experiences_public_time ON experiences.experiences(starts_at,id) WHERE status='PUBLISHED' AND visibility='PUBLIC' AND moderation_status='VISIBLE';
CREATE INDEX experiences_public_geo ON experiences.experiences USING gist(point) WHERE status='PUBLISHED' AND visibility='PUBLIC' AND moderation_status='VISIBLE';
CREATE INDEX experiences_category ON experiences.experiences(category_id,starts_at,id) WHERE status='PUBLISHED' AND visibility='PUBLIC' AND moderation_status='VISIBLE';
CREATE TABLE experiences.idempotency (
 creator_user_id uuid NOT NULL, key uuid NOT NULL,
 request_hash bytea NOT NULL CHECK(octet_length(request_hash)=32),
 experience_id uuid NOT NULL REFERENCES experiences.experiences(id),
 response jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL DEFAULT now()+interval '24 hours',
 PRIMARY KEY(creator_user_id,key)
);
CREATE INDEX experiences_idempotency_expiry ON experiences.idempotency(expires_at);
CREATE TABLE experiences.rate_limits (
 owner_user_id uuid NOT NULL, operation text NOT NULL CHECK(operation IN ('create','publish')),
 window_start timestamptz NOT NULL, count integer NOT NULL CHECK(count>0),
 PRIMARY KEY(owner_user_id,operation,window_start)
);
CREATE TABLE experiences.publishing_restrictions (
 creator_user_id uuid PRIMARY KEY,
 blocked_until timestamptz NOT NULL,
 reason_code text NOT NULL CHECK(char_length(reason_code) BETWEEN 1 AND 80),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE experiences.audit_events (
 id uuid PRIMARY KEY, experience_id uuid NOT NULL, actor_user_id uuid NOT NULL,
 action text NOT NULL, version bigint NOT NULL, request_id text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(experience_id,version)
);
CREATE INDEX experiences_audit_resource ON experiences.audit_events(experience_id,created_at,id);
CREATE INDEX experiences_audit_time ON experiences.audit_events(created_at);

-- Rebuildable projection: no duplicate store, no asynchronous privacy window.
CREATE VIEW experiences.documents AS SELECT e.id,e.creator_user_id,e.created_at,e.starts_at,e.ends_at,e.status,e.visibility,e.moderation_status,e.category_id,e.point,
 (to_jsonb(e)-'point') || jsonb_build_object('location',CASE WHEN e.point IS NULL THEN NULL ELSE
 jsonb_build_object('latitude',round(ST_Y(e.point::geometry)::numeric,6),'longitude',round(ST_X(e.point::geometry)::numeric,6)) END) AS document
 FROM experiences.experiences e;
CREATE VIEW experiences.discovery AS SELECT * FROM experiences.documents
 WHERE status='PUBLISHED' AND visibility='PUBLIC' AND moderation_status='VISIBLE';

-- +goose Down
ALTER TABLE media.bindings DROP CONSTRAINT media_binding_experience;
DROP SCHEMA experiences CASCADE;
DROP SCHEMA media CASCADE;
