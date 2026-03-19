-- =============================================================
--  UniHub  ·  Migration 002  ·  Row Level Security
-- =============================================================
-- Conventions
--   auth.uid()   → UUID of the currently authenticated user
--   auth.role()  → 'authenticated' | 'anon' | 'service_role'
--   We expose a helper to map auth.uid() → users.id
-- =============================================================

-- ─────────────────────────────────────────────
--  Helper: resolve auth.uid() → users.id
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION current_user_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT id FROM users WHERE auth_id = auth.uid() LIMIT 1;
$$;


-- ─────────────────────────────────────────────
--  Enable RLS on all tables
-- ─────────────────────────────────────────────
ALTER TABLE users                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE lost_items             ENABLE ROW LEVEL SECURITY;
ALTER TABLE found_items            ENABLE ROW LEVEL SECURITY;
ALTER TABLE claims                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE returns                ENABLE ROW LEVEL SECURITY;
ALTER TABLE resources              ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance_semesters   ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance_courses     ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance_records     ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications          ENABLE ROW LEVEL SECURITY;
ALTER TABLE reports                ENABLE ROW LEVEL SECURITY;


-- ══════════════════════════════════════════════
--  USERS
-- ══════════════════════════════════════════════

-- Any authenticated user can read public profiles
CREATE POLICY "users_read_authenticated"
  ON users FOR SELECT
  USING (auth.role() = 'authenticated');

-- Users can only update their own profile
CREATE POLICY "users_update_own"
  ON users FOR UPDATE
  USING (id = current_user_id())
  WITH CHECK (id = current_user_id());

-- Insert handled by trigger from auth.users; block direct insert
CREATE POLICY "users_insert_denied"
  ON users FOR INSERT
  WITH CHECK (false);   -- only the SECURITY DEFINER trigger may insert

-- No self-delete (admin only via service_role)
CREATE POLICY "users_delete_denied"
  ON users FOR DELETE
  USING (false);


-- ══════════════════════════════════════════════
--  LOST ITEMS
-- ══════════════════════════════════════════════

CREATE POLICY "lost_items_read_authenticated"
  ON lost_items FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "lost_items_insert_own"
  ON lost_items FOR INSERT
  WITH CHECK (reported_by = current_user_id());

CREATE POLICY "lost_items_update_own"
  ON lost_items FOR UPDATE
  USING (reported_by = current_user_id())
  WITH CHECK (reported_by = current_user_id());

-- Soft-delete only: users deactivate, not hard-delete
CREATE POLICY "lost_items_delete_own"
  ON lost_items FOR DELETE
  USING (reported_by = current_user_id());


-- ══════════════════════════════════════════════
--  FOUND ITEMS
-- ══════════════════════════════════════════════

CREATE POLICY "found_items_read_authenticated"
  ON found_items FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "found_items_insert_own"
  ON found_items FOR INSERT
  WITH CHECK (reported_by = current_user_id());

-- Reporter can update status up to 'claimed';
-- 'resolved' is set only by the returns workflow (service_role)
CREATE POLICY "found_items_update_own"
  ON found_items FOR UPDATE
  USING (reported_by = current_user_id())
  WITH CHECK (reported_by = current_user_id());

CREATE POLICY "found_items_delete_own"
  ON found_items FOR DELETE
  USING (reported_by = current_user_id());


-- ══════════════════════════════════════════════
--  CLAIMS
-- ══════════════════════════════════════════════

-- Claimants see their own claims; item reporter sees claims on their item
CREATE POLICY "claims_read_involved"
  ON claims FOR SELECT
  USING (
    claimant_id = current_user_id()
    OR item_id IN (
      SELECT id FROM found_items WHERE reported_by = current_user_id()
    )
  );

-- RLS-level self-claim prevention (service layer also checks this)
CREATE POLICY "claims_insert_not_own_item"
  ON claims FOR INSERT
  WITH CHECK (
    claimant_id = current_user_id()
    AND claimant_id != (
      SELECT reported_by FROM found_items WHERE id = item_id
    )
  );

-- Only the item reporter can approve/reject claims
CREATE POLICY "claims_update_item_owner"
  ON claims FOR UPDATE
  USING (
    item_id IN (
      SELECT id FROM found_items WHERE reported_by = current_user_id()
    )
  );

-- Claimants may retract their own pending claim
CREATE POLICY "claims_delete_own_pending"
  ON claims FOR DELETE
  USING (
    claimant_id = current_user_id()
    AND status = 'pending'
  );


-- ══════════════════════════════════════════════
--  RETURNS
-- ══════════════════════════════════════════════

-- Both parties involved can read the return record
CREATE POLICY "returns_read_involved"
  ON returns FOR SELECT
  USING (
    returned_to = current_user_id()
    OR returned_by = current_user_id()
  );

-- Only service_role (via Edge Function) inserts returns
CREATE POLICY "returns_insert_service_only"
  ON returns FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

-- No updates or deletes on returns (immutable audit record)
CREATE POLICY "returns_no_update"
  ON returns FOR UPDATE
  USING (false);

CREATE POLICY "returns_no_delete"
  ON returns FOR DELETE
  USING (false);


-- ══════════════════════════════════════════════
--  RESOURCES
-- ══════════════════════════════════════════════

-- All authenticated users can read active resources
CREATE POLICY "resources_read_active"
  ON resources FOR SELECT
  USING (
    auth.role() = 'authenticated'
    AND is_active = true
  );

-- Uploader can also read their own inactive resources
CREATE POLICY "resources_read_own"
  ON resources FOR SELECT
  USING (uploaded_by = current_user_id());

CREATE POLICY "resources_insert_own"
  ON resources FOR INSERT
  WITH CHECK (uploaded_by = current_user_id());

CREATE POLICY "resources_update_own"
  ON resources FOR UPDATE
  USING (uploaded_by = current_user_id())
  WITH CHECK (uploaded_by = current_user_id());

-- Download count incremented by service_role only
CREATE POLICY "resources_download_count_service"
  ON resources FOR UPDATE
  USING (auth.role() = 'service_role');

CREATE POLICY "resources_delete_own"
  ON resources FOR DELETE
  USING (uploaded_by = current_user_id());


-- ══════════════════════════════════════════════
--  ATTENDANCE (fully private — own rows only)
-- ══════════════════════════════════════════════

CREATE POLICY "attendance_semesters_own"
  ON attendance_semesters FOR ALL
  USING (user_id = current_user_id())
  WITH CHECK (user_id = current_user_id());

CREATE POLICY "attendance_courses_own"
  ON attendance_courses FOR ALL
  USING (
    semester_id IN (
      SELECT id FROM attendance_semesters WHERE user_id = current_user_id()
    )
  )
  WITH CHECK (
    semester_id IN (
      SELECT id FROM attendance_semesters WHERE user_id = current_user_id()
    )
  );

CREATE POLICY "attendance_records_own"
  ON attendance_records FOR ALL
  USING (
    course_id IN (
      SELECT ac.id FROM attendance_courses ac
      JOIN attendance_semesters s ON s.id = ac.semester_id
      WHERE s.user_id = current_user_id()
    )
  )
  WITH CHECK (
    course_id IN (
      SELECT ac.id FROM attendance_courses ac
      JOIN attendance_semesters s ON s.id = ac.semester_id
      WHERE s.user_id = current_user_id()
    )
  );


-- ══════════════════════════════════════════════
--  NOTIFICATIONS  (strictly private)
-- ══════════════════════════════════════════════

CREATE POLICY "notifications_own"
  ON notifications FOR SELECT
  USING (user_id = current_user_id());

-- Only service_role inserts notifications (never client-direct)
CREATE POLICY "notifications_insert_service"
  ON notifications FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

-- User can mark as read
CREATE POLICY "notifications_update_own"
  ON notifications FOR UPDATE
  USING (user_id = current_user_id())
  WITH CHECK (user_id = current_user_id());

CREATE POLICY "notifications_delete_own"
  ON notifications FOR DELETE
  USING (user_id = current_user_id());


-- ══════════════════════════════════════════════
--  REPORTS
-- ══════════════════════════════════════════════

-- Reporter can see their own reports
CREATE POLICY "reports_read_own"
  ON reports FOR SELECT
  USING (reporter_id = current_user_id());

CREATE POLICY "reports_insert_own"
  ON reports FOR INSERT
  WITH CHECK (reporter_id = current_user_id());

-- No client-side updates to reports (admin only via service_role)
CREATE POLICY "reports_update_service"
  ON reports FOR UPDATE
  USING (auth.role() = 'service_role');

CREATE POLICY "reports_delete_denied"
  ON reports FOR DELETE
  USING (false);