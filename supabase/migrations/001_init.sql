-- =============================================================
--  UniHub  ·  Migration 001  ·  Core Schema
--  Run order: 001 → 002 → 003 → 004
-- =============================================================

-- ─────────────────────────────────────────────
--  Extensions
-- ─────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";       -- ILIKE fallback + trigram idx
CREATE EXTENSION IF NOT EXISTS "unaccent";       -- accent-insensitive FTS


-- ─────────────────────────────────────────────
--  Custom text-search config  (unaccent-aware)
-- ─────────────────────────────────────────────
CREATE TEXT SEARCH CONFIGURATION unihub (COPY = english);
ALTER  TEXT SEARCH CONFIGURATION unihub
  ALTER MAPPING FOR hword, hword_part, word WITH unaccent, english_stem;


-- ─────────────────────────────────────────────
--  Enums
-- ─────────────────────────────────────────────
CREATE TYPE item_status     AS ENUM ('open', 'claimed', 'resolved', 'expired');
CREATE TYPE claim_status    AS ENUM ('pending', 'approved', 'rejected');
CREATE TYPE resource_type   AS ENUM ('notes', 'ebook', 'pyq', 'other');
CREATE TYPE attendance_status AS ENUM ('present', 'absent', 'cancelled');
CREATE TYPE notification_type AS ENUM (
  'item_claimed', 'claim_approved', 'claim_rejected',
  'item_found_match', 'resource_reported', 'item_expired'
);
CREATE TYPE report_target   AS ENUM ('lost_item', 'found_item', 'resource', 'user');
CREATE TYPE report_status   AS ENUM ('pending', 'reviewed', 'dismissed', 'actioned');


-- ─────────────────────────────────────────────
--  Helper: auto-updated updated_at
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


-- ─────────────────────────────────────────────
--  TABLE: users
--  Mirrors auth.users; stores app-level profile.
--  Populated via trigger on auth.users INSERT.
-- ─────────────────────────────────────────────
CREATE TABLE users (
  id              uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  auth_id         uuid        UNIQUE NOT NULL,        -- fk → auth.users.id
  reg_number      text        UNIQUE NOT NULL
                              CHECK (reg_number ~ '^\d{2}[A-Z]{2,5}\d{4,6}$'),
  name            text        NOT NULL CHECK (char_length(name) BETWEEN 2 AND 100),
  email           text        UNIQUE NOT NULL
                              CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone           text        CHECK (phone ~ '^\+?[0-9]{7,15}$'),
  avatar_url      text,
  is_active       boolean     NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Auto-create profile row when Supabase Auth user is created
CREATE OR REPLACE FUNCTION handle_new_auth_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO users (auth_id, reg_number, name, email)
  VALUES (
    NEW.id,
    NEW.raw_user_meta_data->>'reg_number',
    NEW.raw_user_meta_data->>'name',
    NEW.email
  )
  ON CONFLICT (auth_id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_auth_user();


-- ─────────────────────────────────────────────
--  TABLE: lost_items
-- ─────────────────────────────────────────────
CREATE TABLE lost_items (
  id              uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  reported_by     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title           text        NOT NULL CHECK (char_length(title) BETWEEN 3 AND 120),
  description     text        CHECK (char_length(description) <= 1000),
  category        text        NOT NULL,
  location        text        NOT NULL CHECK (char_length(location) BETWEEN 2 AND 200),
  status          item_status NOT NULL DEFAULT 'open',
  image_url       text,
  thumbnail_url   text,
  fts             tsvector    GENERATED ALWAYS AS (
                    to_tsvector('unihub',
                      coalesce(title, '')       || ' ' ||
                      coalesce(description, '') || ' ' ||
                      coalesce(location, '')    || ' ' ||
                      coalesce(category, ''))
                  ) STORED,
  lost_at         timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER lost_items_updated_at
  BEFORE UPDATE ON lost_items
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ─────────────────────────────────────────────
--  TABLE: found_items
-- ─────────────────────────────────────────────
CREATE TABLE found_items (
  id              uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  reported_by     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title           text        NOT NULL CHECK (char_length(title) BETWEEN 3 AND 120),
  description     text        CHECK (char_length(description) <= 1000),
  category        text        NOT NULL,
  location        text        NOT NULL CHECK (char_length(location) BETWEEN 2 AND 200),
  status          item_status NOT NULL DEFAULT 'open',
  image_url       text,
  thumbnail_url   text,
  fts             tsvector    GENERATED ALWAYS AS (
                    to_tsvector('unihub',
                      coalesce(title, '')       || ' ' ||
                      coalesce(description, '') || ' ' ||
                      coalesce(location, '')    || ' ' ||
                      coalesce(category, ''))
                  ) STORED,
  found_at        timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER found_items_updated_at
  BEFORE UPDATE ON found_items
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ─────────────────────────────────────────────
--  TABLE: claims
--  A user claims ownership of a found_item.
--  Concurrency rule: only one claim allowed while
--  found_item.status = 'open'; enforced by the
--  unique partial index + service-layer WHERE guard.
-- ─────────────────────────────────────────────
CREATE TABLE claims (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  item_id uuid NOT NULL REFERENCES found_items(id) ON DELETE CASCADE,
  claimant_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status claim_status NOT NULL DEFAULT 'pending',
  proof_description text CHECK (char_length(proof_description) <= 500),
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Only one pending claim per item (partial unique index)
CREATE UNIQUE INDEX claims_one_pending_per_item
  ON claims (item_id)
  WHERE status = 'pending';


-- ─────────────────────────────────────────────
--  TABLE: returns
--  Created when a claim is approved and item handed back.
-- ─────────────────────────────────────────────
CREATE TABLE returns (
  id              uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  found_item_id   uuid        NOT NULL UNIQUE REFERENCES found_items(id) ON DELETE CASCADE,
  claim_id        uuid        NOT NULL UNIQUE REFERENCES claims(id)      ON DELETE CASCADE,
  returned_to     uuid        NOT NULL REFERENCES users(id),   -- original owner
  returned_by     uuid        NOT NULL REFERENCES users(id),   -- finder
  notes           text        CHECK (char_length(notes) <= 500),
  returned_at     timestamptz NOT NULL DEFAULT now()
);


-- ─────────────────────────────────────────────
--  TABLE: resources
-- ─────────────────────────────────────────────
CREATE TABLE resources (
  id              uuid          PRIMARY KEY DEFAULT uuid_generate_v4(),
  uploaded_by     uuid          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title           text          NOT NULL CHECK (char_length(title) BETWEEN 3 AND 150),
  description     text          CHECK (char_length(description) <= 800),
  subject         text          NOT NULL,
  resource_type   resource_type NOT NULL,
  file_url        text,                               -- Supabase Storage URL
  external_url    text,                               -- Google Drive / external
  file_size       bigint        CHECK (file_size >= 0),
  download_count  integer       NOT NULL DEFAULT 0
                                CHECK (download_count >= 0),
  is_active       boolean       NOT NULL DEFAULT true,
  fts             tsvector      GENERATED ALWAYS AS (
                    to_tsvector('unihub',
                      coalesce(title, '')       || ' ' ||
                      coalesce(description, '') || ' ' ||
                      coalesce(subject, ''))
                  ) STORED,
  created_at      timestamptz   NOT NULL DEFAULT now(),
  updated_at      timestamptz   NOT NULL DEFAULT now(),

  -- At least one of file_url or external_url must be provided
  CONSTRAINT resource_has_url CHECK (
    file_url IS NOT NULL OR external_url IS NOT NULL
  )
);

CREATE TRIGGER resources_updated_at
  BEFORE UPDATE ON resources
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ─────────────────────────────────────────────
--  TABLE: attendance_semesters
-- ─────────────────────────────────────────────
CREATE TABLE attendance_semesters (
  id          uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        text        NOT NULL CHECK (char_length(name) BETWEEN 2 AND 80),
  start_date  date        NOT NULL,
  end_date    date        NOT NULL,
  is_active   boolean     NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT semester_dates_valid CHECK (end_date > start_date),
  -- Only one active semester per user
  CONSTRAINT one_active_semester UNIQUE NULLS NOT DISTINCT (user_id, is_active)
);

-- Partial unique index: only one active semester per user
CREATE UNIQUE INDEX one_active_semester_per_user
  ON attendance_semesters (user_id)
  WHERE is_active = true;


-- ─────────────────────────────────────────────
--  TABLE: attendance_courses
-- ─────────────────────────────────────────────
CREATE TABLE attendance_courses (
  id              uuid        PRIMARY KEY DEFAULT uuid_generate_v4(),
  semester_id     uuid        NOT NULL REFERENCES attendance_semesters(id) ON DELETE CASCADE,
  name            text        NOT NULL CHECK (char_length(name) BETWEEN 2 AND 100),
  code            text        NOT NULL CHECK (char_length(code) BETWEEN 2 AND 20),
  total_classes   integer     NOT NULL DEFAULT 0 CHECK (total_classes >= 0),
  attended        integer     NOT NULL DEFAULT 0 CHECK (attended >= 0),
  required_pct    integer     NOT NULL DEFAULT 75
                              CHECK (required_pct BETWEEN 0 AND 100),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT attended_lte_total CHECK (attended <= total_classes),
  CONSTRAINT unique_course_per_semester UNIQUE (semester_id, code)
);

CREATE TRIGGER attendance_courses_updated_at
  BEFORE UPDATE ON attendance_courses
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ─────────────────────────────────────────────
--  TABLE: attendance_records
--  One row per class day per course.
--  Aggregates are maintained on attendance_courses
--  via trigger to avoid expensive COUNT queries.
-- ─────────────────────────────────────────────
CREATE TABLE attendance_records (
  id          uuid              PRIMARY KEY DEFAULT uuid_generate_v4(),
  course_id   uuid              NOT NULL REFERENCES attendance_courses(id) ON DELETE CASCADE,
  date        date              NOT NULL,
  status      attendance_status NOT NULL,
  notes       text              CHECK (char_length(notes) <= 200),
  created_at  timestamptz       NOT NULL DEFAULT now(),

  CONSTRAINT one_record_per_day UNIQUE (course_id, date)
);

-- Trigger: keep total_classes / attended in sync
CREATE OR REPLACE FUNCTION sync_attendance_counts()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE attendance_courses SET
      total_classes = total_classes + 1,
      attended      = attended + CASE WHEN NEW.status = 'present' THEN 1 ELSE 0 END,
      updated_at    = now()
    WHERE id = NEW.course_id;

  ELSIF TG_OP = 'UPDATE' AND OLD.status != NEW.status THEN
    UPDATE attendance_courses SET
      attended = attended
        - CASE WHEN OLD.status = 'present' THEN 1 ELSE 0 END
        + CASE WHEN NEW.status = 'present' THEN 1 ELSE 0 END,
      updated_at = now()
    WHERE id = NEW.course_id;

  ELSIF TG_OP = 'DELETE' THEN
    UPDATE attendance_courses SET
      total_classes = total_classes - 1,
      attended      = attended - CASE WHEN OLD.status = 'present' THEN 1 ELSE 0 END,
      updated_at    = now()
    WHERE id = OLD.course_id;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER attendance_records_sync
  AFTER INSERT OR UPDATE OR DELETE ON attendance_records
  FOR EACH ROW EXECUTE FUNCTION sync_attendance_counts();


-- ─────────────────────────────────────────────
--  TABLE: notifications
-- ─────────────────────────────────────────────
CREATE TABLE notifications (
  id          uuid              PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id     uuid              NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type        notification_type NOT NULL,
  title       text              NOT NULL CHECK (char_length(title) BETWEEN 1 AND 120),
  body        text              CHECK (char_length(body) <= 400),
  payload     jsonb             NOT NULL DEFAULT '{}',
  is_read     boolean           NOT NULL DEFAULT false,
  created_at  timestamptz       NOT NULL DEFAULT now()
);


-- ─────────────────────────────────────────────
--  TABLE: reports
--  Polymorphic: target_type + target_id point to
--  any reportable entity. Resolved by admin.
-- ─────────────────────────────────────────────
CREATE TABLE reports (
  id          uuid          PRIMARY KEY DEFAULT uuid_generate_v4(),
  reporter_id uuid          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_type report_target NOT NULL,
  target_id   uuid          NOT NULL,
  reason      text          NOT NULL CHECK (char_length(reason) BETWEEN 5 AND 500),
  status      report_status NOT NULL DEFAULT 'pending',
  admin_notes text          CHECK (char_length(admin_notes) <= 500),
  created_at  timestamptz   NOT NULL DEFAULT now(),
  resolved_at timestamptz,

  -- One report per user per target
  CONSTRAINT one_report_per_target UNIQUE (reporter_id, target_type, target_id)
);