-- +goose Up
-- +goose StatementBegin
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS tele_drive;

CREATE TABLE IF NOT EXISTS tele_drive.source (
    source_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_type text NOT NULL DEFAULT 'telegram_channel',
    driver text NOT NULL DEFAULT 'teldrive',
    external_id text NOT NULL,
    display_name text,
    teldrive_user_id bigint,
    teldrive_channel_id bigint,
    telegram_channel_id bigint,
    root_teldrive_file_id uuid,
    import_cursor jsonb NOT NULL DEFAULT '{}'::jsonb,
    state text NOT NULL DEFAULT 'active',
    config jsonb NOT NULL DEFAULT '{}'::jsonb,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT source_type_non_empty CHECK (length(trim(source_type)) > 0),
    CONSTRAINT source_driver_non_empty CHECK (length(trim(driver)) > 0),
    CONSTRAINT source_external_id_non_empty CHECK (length(trim(external_id)) > 0),
    CONSTRAINT source_state_non_empty CHECK (length(trim(state)) > 0)
);

CREATE TABLE IF NOT EXISTS tele_drive.import_job (
    import_job_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id uuid NOT NULL REFERENCES tele_drive.source(source_id) ON DELETE RESTRICT,
    job_type text NOT NULL DEFAULT 'scan',
    status text NOT NULL DEFAULT 'queued',
    requested_by text,
    teldrive_user_id bigint,
    teldrive_channel_id bigint,
    limit_count integer,
    convert_photos boolean NOT NULL DEFAULT true,
    dry_run boolean NOT NULL DEFAULT false,
    cursor_before jsonb NOT NULL DEFAULT '{}'::jsonb,
    cursor_after jsonb NOT NULL DEFAULT '{}'::jsonb,
    request jsonb NOT NULL DEFAULT '{}'::jsonb,
    result jsonb NOT NULL DEFAULT '{}'::jsonb,
    scanned_count integer NOT NULL DEFAULT 0,
    imported_count integer NOT NULL DEFAULT 0,
    converted_count integer NOT NULL DEFAULT 0,
    skipped_count integer NOT NULL DEFAULT 0,
    error_count integer NOT NULL DEFAULT 0,
    last_error text,
    started_at timestamptz,
    finished_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT import_job_type_non_empty CHECK (length(trim(job_type)) > 0),
    CONSTRAINT import_job_status_non_empty CHECK (length(trim(status)) > 0),
    CONSTRAINT import_job_limit_positive CHECK (limit_count IS NULL OR limit_count > 0),
    CONSTRAINT import_job_counts_non_negative CHECK (
        scanned_count >= 0
        AND imported_count >= 0
        AND converted_count >= 0
        AND skipped_count >= 0
        AND error_count >= 0
    ),
    CONSTRAINT import_job_time_order CHECK (
        started_at IS NULL
        OR finished_at IS NULL
        OR finished_at >= started_at
    )
);

CREATE TABLE IF NOT EXISTS tele_drive.imported_asset (
    asset_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id uuid NOT NULL REFERENCES tele_drive.source(source_id) ON DELETE RESTRICT,
    source_media_key text NOT NULL,
    original_message_id integer,
    importer_channel_id bigint,
    importer_original_msg_id integer,
    media_kind text NOT NULL,
    asset_type text NOT NULL DEFAULT 'file',
    display_name text NOT NULL,
    mime_type text,
    category text,
    size_bytes bigint,
    caption text,
    current_revision_id uuid,
    last_seen_job_id uuid REFERENCES tele_drive.import_job(import_job_id) ON DELETE SET NULL,
    state text NOT NULL DEFAULT 'active',
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT imported_asset_source_media_key_non_empty CHECK (length(trim(source_media_key)) > 0),
    CONSTRAINT imported_asset_media_kind_non_empty CHECK (length(trim(media_kind)) > 0),
    CONSTRAINT imported_asset_asset_type_non_empty CHECK (length(trim(asset_type)) > 0),
    CONSTRAINT imported_asset_display_name_non_empty CHECK (length(trim(display_name)) > 0),
    CONSTRAINT imported_asset_state_non_empty CHECK (length(trim(state)) > 0),
    CONSTRAINT imported_asset_size_non_negative CHECK (size_bytes IS NULL OR size_bytes >= 0)
);

CREATE TABLE IF NOT EXISTS tele_drive.asset_revision (
    revision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id uuid NOT NULL REFERENCES tele_drive.imported_asset(asset_id) ON DELETE CASCADE,
    revision_no integer NOT NULL,
    import_job_id uuid REFERENCES tele_drive.import_job(import_job_id) ON DELETE SET NULL,
    storage_backend text NOT NULL DEFAULT 'teldrive',
    teldrive_file_id uuid,
    teldrive_user_id bigint,
    teldrive_channel_id bigint,
    importer_imported_msg_id integer,
    converted_from_photo boolean NOT NULL DEFAULT false,
    name text NOT NULL,
    mime_type text,
    category text,
    size_bytes bigint,
    content_hash text,
    is_current boolean NOT NULL DEFAULT true,
    state text NOT NULL DEFAULT 'active',
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT asset_revision_revision_no_positive CHECK (revision_no > 0),
    CONSTRAINT asset_revision_storage_backend_non_empty CHECK (length(trim(storage_backend)) > 0),
    CONSTRAINT asset_revision_name_non_empty CHECK (length(trim(name)) > 0),
    CONSTRAINT asset_revision_state_non_empty CHECK (length(trim(state)) > 0),
    CONSTRAINT asset_revision_size_non_negative CHECK (size_bytes IS NULL OR size_bytes >= 0)
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'imported_asset_current_revision_id_fkey'
          AND conrelid = 'tele_drive.imported_asset'::regclass
    ) THEN
        ALTER TABLE tele_drive.imported_asset
            ADD CONSTRAINT imported_asset_current_revision_id_fkey
            FOREIGN KEY (current_revision_id)
            REFERENCES tele_drive.asset_revision(revision_id)
            ON DELETE SET NULL;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS tele_drive.asset_part (
    asset_part_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    revision_id uuid NOT NULL REFERENCES tele_drive.asset_revision(revision_id) ON DELETE CASCADE,
    part_no integer NOT NULL,
    teldrive_part_id integer,
    telegram_channel_id bigint,
    telegram_message_id integer,
    original_message_id integer,
    byte_offset bigint,
    size_bytes bigint,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT asset_part_part_no_positive CHECK (part_no > 0),
    CONSTRAINT asset_part_byte_offset_non_negative CHECK (byte_offset IS NULL OR byte_offset >= 0),
    CONSTRAINT asset_part_size_non_negative CHECK (size_bytes IS NULL OR size_bytes >= 0)
);

CREATE TABLE IF NOT EXISTS tele_drive.bridge_session (
    bridge_session_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id uuid REFERENCES tele_drive.source(source_id) ON DELETE SET NULL,
    session_kind text NOT NULL DEFAULT 'telegram_user',
    driver text NOT NULL DEFAULT 'gotd',
    secret_ref text,
    secret_sha256 text,
    teldrive_user_id bigint,
    teldrive_session_hash text,
    teldrive_session_date integer,
    subject text,
    state text NOT NULL DEFAULT 'active',
    expires_at timestamptz,
    last_used_at timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT bridge_session_kind_non_empty CHECK (length(trim(session_kind)) > 0),
    CONSTRAINT bridge_session_driver_non_empty CHECK (length(trim(driver)) > 0),
    CONSTRAINT bridge_session_state_non_empty CHECK (length(trim(state)) > 0)
);

CREATE TABLE IF NOT EXISTS tele_drive.bridge_token (
    bridge_token_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id uuid REFERENCES tele_drive.source(source_id) ON DELETE SET NULL,
    bridge_session_id uuid REFERENCES tele_drive.bridge_session(bridge_session_id) ON DELETE SET NULL,
    token_hash text NOT NULL,
    token_prefix text,
    subject text NOT NULL,
    scopes text[] NOT NULL DEFAULT ARRAY[]::text[],
    state text NOT NULL DEFAULT 'active',
    issued_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    expires_at timestamptz,
    last_used_at timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    updated_at timestamptz NOT NULL DEFAULT timezone('utc'::text, now()),
    CONSTRAINT bridge_token_hash_non_empty CHECK (length(trim(token_hash)) > 0),
    CONSTRAINT bridge_token_subject_non_empty CHECK (length(trim(subject)) > 0),
    CONSTRAINT bridge_token_state_non_empty CHECK (length(trim(state)) > 0),
    CONSTRAINT bridge_token_time_order CHECK (expires_at IS NULL OR expires_at >= issued_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_source_driver_external_user
    ON tele_drive.source (driver, source_type, external_id, (COALESCE(teldrive_user_id, 0)));
CREATE INDEX IF NOT EXISTS idx_source_teldrive_channel
    ON tele_drive.source (teldrive_channel_id);
CREATE INDEX IF NOT EXISTS idx_source_telegram_channel
    ON tele_drive.source (telegram_channel_id);
CREATE INDEX IF NOT EXISTS idx_source_state
    ON tele_drive.source (state);

CREATE INDEX IF NOT EXISTS idx_import_job_source_created_at
    ON tele_drive.import_job (source_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_import_job_status
    ON tele_drive.import_job (status);

CREATE UNIQUE INDEX IF NOT EXISTS ux_imported_asset_source_media_key
    ON tele_drive.imported_asset (source_id, source_media_key);
CREATE UNIQUE INDEX IF NOT EXISTS ux_imported_asset_source_original_message
    ON tele_drive.imported_asset (source_id, original_message_id)
    WHERE original_message_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_imported_asset_importer_marker
    ON tele_drive.imported_asset (importer_channel_id, importer_original_msg_id)
    WHERE importer_channel_id IS NOT NULL AND importer_original_msg_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_imported_asset_current_revision
    ON tele_drive.imported_asset (current_revision_id);
CREATE INDEX IF NOT EXISTS idx_imported_asset_state
    ON tele_drive.imported_asset (state);

CREATE UNIQUE INDEX IF NOT EXISTS ux_asset_revision_asset_revision_no
    ON tele_drive.asset_revision (asset_id, revision_no);
CREATE UNIQUE INDEX IF NOT EXISTS ux_asset_revision_one_current
    ON tele_drive.asset_revision (asset_id)
    WHERE is_current;
CREATE UNIQUE INDEX IF NOT EXISTS ux_asset_revision_teldrive_file
    ON tele_drive.asset_revision (teldrive_file_id)
    WHERE storage_backend = 'teldrive' AND teldrive_file_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_asset_revision_import_job
    ON tele_drive.asset_revision (import_job_id);
CREATE INDEX IF NOT EXISTS idx_asset_revision_state
    ON tele_drive.asset_revision (state);

CREATE UNIQUE INDEX IF NOT EXISTS ux_asset_part_revision_part_no
    ON tele_drive.asset_part (revision_id, part_no);
CREATE INDEX IF NOT EXISTS idx_asset_part_teldrive_part
    ON tele_drive.asset_part (teldrive_part_id)
    WHERE teldrive_part_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_asset_part_telegram_message
    ON tele_drive.asset_part (telegram_channel_id, telegram_message_id)
    WHERE telegram_channel_id IS NOT NULL AND telegram_message_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_bridge_session_source
    ON tele_drive.bridge_session (source_id);
CREATE INDEX IF NOT EXISTS idx_bridge_session_teldrive_user
    ON tele_drive.bridge_session (teldrive_user_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_bridge_session_teldrive_hash
    ON tele_drive.bridge_session (teldrive_user_id, teldrive_session_hash)
    WHERE teldrive_user_id IS NOT NULL AND teldrive_session_hash IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_bridge_token_hash
    ON tele_drive.bridge_token (token_hash);
CREATE INDEX IF NOT EXISTS idx_bridge_token_source
    ON tele_drive.bridge_token (source_id);
CREATE INDEX IF NOT EXISTS idx_bridge_token_session
    ON tele_drive.bridge_token (bridge_session_id);
CREATE INDEX IF NOT EXISTS idx_bridge_token_expiry
    ON tele_drive.bridge_token (expires_at)
    WHERE expires_at IS NOT NULL;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS tele_drive.bridge_token;
DROP TABLE IF EXISTS tele_drive.bridge_session;
ALTER TABLE IF EXISTS tele_drive.imported_asset
    DROP CONSTRAINT IF EXISTS imported_asset_current_revision_id_fkey;
DROP TABLE IF EXISTS tele_drive.asset_part;
DROP TABLE IF EXISTS tele_drive.asset_revision;
DROP TABLE IF EXISTS tele_drive.imported_asset;
DROP TABLE IF EXISTS tele_drive.import_job;
DROP TABLE IF EXISTS tele_drive.source;
DROP SCHEMA IF EXISTS tele_drive;
-- +goose StatementEnd
