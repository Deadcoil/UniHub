-- =============================================================
--  UniHub  ·  Migration 003  ·  Indexes
--  All B-Tree + GIN indexes for performance & FTS
-- =============================================================

-- ─────────────────────────────────────────────
--  users
-- ─────────────────────────────────────────────
CREATE INDEX idx_users_auth_id        ON users (auth_id);
CREATE INDEX idx_users_reg_number     ON users (reg_number);
CREATE INDEX idx_users_email          ON users (lower(email));  -- case-insensitive lookup


-- ─────────────────────────────────────────────
--  lost_items
-- ─────────────────────────────────────────────
-- FTS (full-text search via tsvector column)
CREATE INDEX idx_lost_items_fts       ON lost_items USING GIN (fts);

-- Browse / filter queries
CREATE INDEX idx_lost_items_status    ON lost_items (status);
CREATE INDEX idx_lost_items_category  ON lost_items (category);
CREATE INDEX idx_lost_items_reporter  ON lost_items (reported_by);
CREATE INDEX idx_lost_items_created   ON lost_items (created_at DESC);

-- Dashboard stat: count by status fast
CREATE INDEX idx_lost_items_status_created
  ON lost_items (status, created_at DESC);

-- Trigram index for partial / ILIKE fallback
CREATE INDEX idx_lost_items_title_trgm
  ON lost_items USING GIN (title gin_trgm_ops);


-- ─────────────────────────────────────────────
--  found_items
-- ─────────────────────────────────────────────
CREATE INDEX idx_found_items_fts      ON found_items USING GIN (fts);
CREATE INDEX idx_found_items_status   ON found_items (status);
CREATE INDEX idx_found_items_category ON found_items (category);
CREATE INDEX idx_found_items_reporter ON found_items (reported_by);
CREATE INDEX idx_found_items_created  ON found_items (created_at DESC);

CREATE INDEX idx_found_items_status_created
  ON found_items (status, created_at DESC);

CREATE INDEX idx_found_items_title_trgm
  ON found_items USING GIN (title gin_trgm_ops);


-- ─────────────────────────────────────────────
--  claims
-- ─────────────────────────────────────────────
-- Primary access patterns
CREATE INDEX idx_claims_item_id       ON claims (item_id);
CREATE INDEX idx_claims_claimant      ON claims (claimant_id);
CREATE INDEX idx_claims_status        ON claims (status);
CREATE INDEX idx_claims_created       ON claims (created_at DESC);

-- Concurrency index already created in 001 as a UNIQUE partial index:
--   claims_one_pending_per_item ON claims(item_id) WHERE status = 'pending'
--   (no duplicate needed here)


-- ─────────────────────────────────────────────
--  returns
-- ─────────────────────────────────────────────
CREATE INDEX idx_returns_returned_to  ON returns (returned_to);
CREATE INDEX idx_returns_returned_by  ON returns (returned_by);
CREATE INDEX idx_returns_returned_at  ON returns (returned_at DESC);


-- ─────────────────────────────────────────────
--  resources
-- ─────────────────────────────────────────────
CREATE INDEX idx_resources_fts        ON resources USING GIN (fts);
CREATE INDEX idx_resources_uploader   ON resources (uploaded_by);
CREATE INDEX idx_resources_type       ON resources (resource_type);
CREATE INDEX idx_resources_subject    ON resources (lower(subject));
CREATE INDEX idx_resources_active     ON resources (is_active, created_at DESC);
CREATE INDEX idx_resources_downloads  ON resources (download_count DESC);

CREATE INDEX idx_resources_title_trgm
  ON resources USING GIN (title gin_trgm_ops);


-- ─────────────────────────────────────────────
--  attendance_semesters
-- ─────────────────────────────────────────────
CREATE INDEX idx_semesters_user       ON attendance_semesters (user_id);
CREATE INDEX idx_semesters_active     ON attendance_semesters (user_id, is_active);
-- Partial unique index (declared in migration 001 — not repeated)


-- ─────────────────────────────────────────────
--  attendance_courses
-- ─────────────────────────────────────────────
CREATE INDEX idx_courses_semester     ON attendance_courses (semester_id);

-- Computed attendance percentage (used for progress bar, ordering)
CREATE INDEX idx_courses_attendance_pct
  ON attendance_courses ((
    CASE WHEN total_classes = 0 THEN 0
         ELSE ROUND((attended::numeric / total_classes) * 100)
    END
  ));


-- ─────────────────────────────────────────────
--  attendance_records
-- ─────────────────────────────────────────────
CREATE INDEX idx_records_course_date  ON attendance_records (course_id, date DESC);
CREATE INDEX idx_records_status       ON attendance_records (status);


-- ─────────────────────────────────────────────
--  notifications
-- ─────────────────────────────────────────────
CREATE INDEX idx_notifications_user   ON notifications (user_id, created_at DESC);
CREATE INDEX idx_notifications_unread ON notifications (user_id, is_read)
  WHERE is_read = false;   -- partial index: only unread rows


-- ─────────────────────────────────────────────
--  reports
-- ─────────────────────────────────────────────
CREATE INDEX idx_reports_reporter     ON reports (reporter_id);
CREATE INDEX idx_reports_target       ON reports (target_type, target_id);
CREATE INDEX idx_reports_status       ON reports (status);
CREATE INDEX idx_reports_created      ON reports (created_at DESC);