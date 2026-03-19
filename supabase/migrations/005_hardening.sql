-- =============================================================
--  UniHub  ·  Migration 005  ·  Final Hardening Pass
--  Patches on top of 001–004. Run after all prior migrations.
--  Sections:
--    A. Soft delete
--    B. expires_at
--    C. Audit log table
--    D. RLS policy cleanup + additions
--    E. Atomic RPC functions
--    F. Index additions
--    G. Constraint refinements
--    H. Data-consistency FK fixes
-- =============================================================


-- ══════════════════════════════════════════════
--  A. SOFT DELETE
--  Add deleted_at to every user-owned table.
--  A NULL value means "alive"; a timestamp means
--  "soft-deleted". Views enforce the exclusion so
--  queries don't need a WHERE filter every time.
-- ══════════════════════════════════════════════

ALTER TABLE lost_items   ADD COLUMN IF NOT EXISTS deleted_at timestamptz DEFAULT NULL;
ALTER TABLE found_items  ADD COLUMN IF NOT EXISTS deleted_at timestamptz DEFAULT NULL;
ALTER TABLE resources    ADD COLUMN IF NOT EXISTS deleted_at timestamptz DEFAULT NULL;
ALTER TABLE claims       ADD COLUMN IF NOT EXISTS deleted_at timestamptz DEFAULT NULL;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS deleted_at timestamptz DEFAULT NULL;

-- ── Partial indexes so live-row lookups stay fast ──────────────
CREATE INDEX IF NOT EXISTS idx_lost_items_alive
  ON lost_items (created_at DESC) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_found_items_alive
  ON found_items (created_at DESC) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_resources_alive
  ON resources (created_at DESC) WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_claims_alive
  ON claims (item_id, status) WHERE deleted_at IS NULL;

-- ── Convenience views (used by all service queries) ────────────
CREATE OR REPLACE VIEW active_lost_items AS
  SELECT * FROM lost_items WHERE deleted_at IS NULL;

CREATE OR REPLACE VIEW active_found_items AS
  SELECT * FROM found_items WHERE deleted_at IS NULL;

CREATE OR REPLACE VIEW active_resources AS
  SELECT * FROM resources WHERE deleted_at IS NULL AND is_active = true;

-- ── Soft-delete helper function ────────────────────────────────
CREATE OR REPLACE FUNCTION soft_delete(
  p_table  text,
  p_id     uuid,
  p_actor  uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  EXECUTE format(
    'UPDATE %I SET deleted_at = now(), updated_at = now()
     WHERE id = $1 AND deleted_at IS NULL',
    p_table
  ) USING p_id;
END;
$$;


-- ══════════════════════════════════════════════
--  B. EXPIRES_AT  +  configurable default
-- ══════════════════════════════════════════════

ALTER TABLE lost_items
ADD COLUMN IF NOT EXISTS expires_at timestamptz;

UPDATE lost_items
SET expires_at = created_at + INTERVAL '30 days'
WHERE expires_at IS NULL;

ALTER TABLE found_items
ADD COLUMN IF NOT EXISTS expires_at timestamptz;

UPDATE found_items
SET expires_at = created_at + INTERVAL '30 days'
WHERE expires_at IS NULL;

-- Index for the expiry cron (replaces the created_at arithmetic in 004)
CREATE INDEX IF NOT EXISTS idx_lost_items_expires
  ON lost_items (expires_at) WHERE status = 'open' AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_found_items_expires
  ON found_items (expires_at) WHERE status = 'open' AND deleted_at IS NULL;

-- Update cron job to use the generated column (cleaner query plan)
-- SELECT cron.unschedule('expire-stale-items');
-- SELECT cron.schedule(
--   'expire-stale-items',
--   '0 2 * * *',
--   $$
--     UPDATE lost_items
--     SET status = 'expired', updated_at = now()
--     WHERE status = 'open'
--       AND deleted_at IS NULL
--       AND expires_at <= now();

--     UPDATE found_items
--     SET status = 'expired', updated_at = now()
--     WHERE status = 'open'
--       AND deleted_at IS NULL
--       AND expires_at <= now();
--   $$
-- );


-- ══════════════════════════════════════════════
--  C. AUDIT LOG TABLE
-- ══════════════════════════════════════════════

CREATE TYPE audit_action AS ENUM (
  'create', 'update', 'delete', 'soft_delete',
  'claim_submitted', 'claim_approved', 'claim_rejected',
  'item_returned', 'report_filed', 'report_resolved',
  'login', 'logout', 'password_change'
);

CREATE TABLE audit_logs (
  id           uuid         PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id      uuid         REFERENCES users(id) ON DELETE SET NULL,  -- NULL = system action
  action_type  audit_action NOT NULL,
  entity_type  text         NOT NULL CHECK (char_length(entity_type) <= 50),
  entity_id    uuid         NOT NULL,
  old_data     jsonb,       -- snapshot before change (UPDATE/DELETE)
  new_data     jsonb,       -- snapshot after change (INSERT/UPDATE)
  metadata     jsonb        NOT NULL DEFAULT '{}',
  ip_address   inet,
  user_agent   text         CHECK (char_length(user_agent) <= 500),
  created_at   timestamptz  NOT NULL DEFAULT now()
);

-- Audit logs are append-only — no UPDATE or DELETE ever
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "audit_logs_insert_service_only"
  ON audit_logs FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

CREATE POLICY "audit_logs_read_own"
  ON audit_logs FOR SELECT
  USING (user_id = current_user_id());

CREATE POLICY "audit_logs_no_update"
  ON audit_logs FOR UPDATE
  USING (false);

CREATE POLICY "audit_logs_no_delete"
  ON audit_logs FOR DELETE
  USING (false);

-- Indexes for audit query patterns
CREATE INDEX idx_audit_user_id     ON audit_logs (user_id, created_at DESC);
CREATE INDEX idx_audit_entity      ON audit_logs (entity_type, entity_id, created_at DESC);
CREATE INDEX idx_audit_action      ON audit_logs (action_type, created_at DESC);
CREATE INDEX idx_audit_created     ON audit_logs (created_at DESC);

-- ── Automatic audit trigger factory ───────────────────────────
CREATE OR REPLACE FUNCTION audit_trigger_fn()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_action audit_action;
  v_actor  uuid;
BEGIN
  v_actor := current_user_id();

  IF    TG_OP = 'INSERT' THEN v_action := 'create';
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
      v_action := 'soft_delete';
    ELSE
      v_action := 'update';
    END IF;
  ELSIF TG_OP = 'DELETE' THEN v_action := 'delete';
  END IF;

  INSERT INTO audit_logs (user_id, action_type, entity_type, entity_id, old_data, new_data)
  VALUES (
    v_actor,
    v_action,
    TG_TABLE_NAME,
    COALESCE(NEW.id, OLD.id),
    CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) ELSE NULL END,
    CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) ELSE NULL END
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- Attach audit triggers to high-value tables
CREATE TRIGGER audit_lost_items
  AFTER INSERT OR UPDATE OR DELETE ON lost_items
  FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();

CREATE TRIGGER audit_found_items
  AFTER INSERT OR UPDATE OR DELETE ON found_items
  FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();

CREATE TRIGGER audit_claims
  AFTER INSERT OR UPDATE OR DELETE ON claims
  FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();

CREATE TRIGGER audit_returns
  AFTER INSERT OR UPDATE OR DELETE ON returns
  FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();

CREATE TRIGGER audit_resources
  AFTER INSERT OR UPDATE OR DELETE ON resources
  FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();

CREATE TRIGGER audit_reports
  AFTER INSERT OR UPDATE OR DELETE ON reports
  FOR EACH ROW EXECUTE FUNCTION audit_trigger_fn();


-- ══════════════════════════════════════════════
--  D. RLS POLICY CLEANUP + ADDITIONS
--  Patches to 002_rls.sql policies.
--  All policies now filter deleted_at IS NULL.
-- ══════════════════════════════════════════════

-- ── lost_items: exclude soft-deleted rows from public read ─────
DROP POLICY IF EXISTS "lost_items_read_authenticated" ON lost_items;
CREATE POLICY "lost_items_read_authenticated"
  ON lost_items FOR SELECT
  USING (
    auth.role() = 'authenticated'
    AND deleted_at IS NULL
  );

-- ── found_items: same ──────────────────────────────────────────
DROP POLICY IF EXISTS "found_items_read_authenticated" ON found_items;
CREATE POLICY "found_items_read_authenticated"
  ON found_items FOR SELECT
  USING (
    auth.role() = 'authenticated'
    AND deleted_at IS NULL
  );

-- ── resources: public read excludes soft-deleted ──────────────
DROP POLICY IF EXISTS "resources_read_active" ON resources;
CREATE POLICY "resources_read_active"
  ON resources FOR SELECT
  USING (
    auth.role() = 'authenticated'
    AND is_active = true
    AND deleted_at IS NULL
  );

DROP POLICY IF EXISTS "resources_read_own" ON resources;
CREATE POLICY "resources_read_own"
  ON resources FOR SELECT
  USING (
    uploaded_by = current_user_id()
    AND deleted_at IS NULL
  );

-- ── claims: exclude soft-deleted ──────────────────────────────
DROP POLICY IF EXISTS "claims_read_involved" ON claims;
CREATE POLICY "claims_read_involved"
  ON claims FOR SELECT
  USING (
    deleted_at IS NULL
    AND (
      claimant_id = current_user_id()
      OR item_id IN (
        SELECT id FROM found_items WHERE reported_by = current_user_id()
      )
    )
  );

-- ── notifications: exclude soft-deleted ───────────────────────
DROP POLICY IF EXISTS "notifications_own" ON notifications;
CREATE POLICY "notifications_own"
  ON notifications FOR SELECT
  USING (
    user_id = current_user_id()
    AND deleted_at IS NULL
  );

-- ── Admin role policies (future extensibility) ─────────────────
-- We check for a custom claim 'app_role' = 'admin' in the JWT.
-- Supabase allows custom claims via a custom access token hook.

CREATE POLICY "admin_read_all_lost_items"
  ON lost_items FOR SELECT
  USING ((auth.jwt() ->> 'app_role') = 'admin');

CREATE POLICY "admin_read_all_found_items"
  ON found_items FOR SELECT
  USING ((auth.jwt() ->> 'app_role') = 'admin');

CREATE POLICY "admin_read_all_reports"
  ON reports FOR SELECT
  USING ((auth.jwt() ->> 'app_role') = 'admin');

CREATE POLICY "admin_update_reports"
  ON reports FOR UPDATE
  USING ((auth.jwt() ->> 'app_role') = 'admin');

CREATE POLICY "admin_read_audit_logs"
  ON audit_logs FOR SELECT
  USING ((auth.jwt() ->> 'app_role') = 'admin');


-- ══════════════════════════════════════════════
--  E. ATOMIC RPC FUNCTIONS  (Supabase RPC)
--  Called from service layer:
--    supabase.rpc('rpc_claim_item', { ... })
--  Each function runs inside a transaction block.
--  Returns jsonb so callers get structured results.
-- ══════════════════════════════════════════════

-- ── E1: rpc_claim_item ────────────────────────────────────────
-- Atomically:
--   1. Verify found_item is open and not the caller's own item
--   2. Insert claim row
--   3. Update found_item status → 'claimed'
--   4. Insert notification for the item reporter
-- Returns: { claim_id, status }  or raises an exception
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_claim_item(
  p_item_id          uuid,
  p_proof_description text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_claimant_id  uuid := current_user_id();
  v_item         found_items%ROWTYPE;
  v_claim_id     uuid;
BEGIN
  -- 1. Lock & validate the item row
  SELECT * INTO v_item
  FROM found_items
  WHERE id = p_item_id
    AND deleted_at IS NULL
  FOR UPDATE;                         -- row-level lock prevents concurrent claims

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ITEM_NOT_FOUND' USING ERRCODE = 'P0002';
  END IF;

  IF v_item.status != 'open' THEN
    RAISE EXCEPTION 'ITEM_ALREADY_CLAIMED' USING ERRCODE = 'P0003';
  END IF;

  IF v_item.reported_by = v_claimant_id THEN
    RAISE EXCEPTION 'CANNOT_CLAIM_OWN_ITEM' USING ERRCODE = 'P0004';
  END IF;

  -- 2. Insert claim
  INSERT INTO claims (item_id, claimant_id, proof_description)
  VALUES (p_item_id, v_claimant_id, p_proof_description)
  RETURNING id INTO v_claim_id;

  -- 3. Update item status
  UPDATE found_items
  SET status = 'claimed', updated_at = now()
  WHERE id = p_item_id;

  -- 4. Notify the item reporter (fire-and-forget row; Realtime picks it up)
  INSERT INTO notifications (user_id, type, title, body, payload)
  VALUES (
    v_item.reported_by,
    'item_claimed',
    'Someone claimed your found item',
    'A claim has been submitted for "' || v_item.title || '"',
    jsonb_build_object(
      'claim_id',  v_claim_id,
      'item_id',   p_item_id,
      'item_title', v_item.title
    )
  );

  RETURN jsonb_build_object('claim_id', v_claim_id, 'status', 'pending');
END;
$$;


-- ── E2: rpc_approve_claim ─────────────────────────────────────
-- Atomically:
--   1. Validate caller owns the found_item
--   2. Update claim status → 'approved'
--   3. Reject all other pending claims for the same item
--   4. Update found_item status → 'resolved'
--   5. Insert return record
--   6. Notify claimant (approved) + others (rejected)
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_approve_claim(
  p_claim_id uuid,
  p_notes    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor      uuid := current_user_id();
  v_claim      claims%ROWTYPE;
  v_item       found_items%ROWTYPE;
  v_return_id  uuid;
BEGIN
  -- 1. Fetch & lock claim + item
  SELECT * INTO v_claim
  FROM claims
  WHERE id = p_claim_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'CLAIM_NOT_FOUND' USING ERRCODE = 'P0005';
  END IF;

  IF v_claim.status != 'pending' THEN
    RAISE EXCEPTION 'CLAIM_NOT_PENDING' USING ERRCODE = 'P0006';
  END IF;

  SELECT * INTO v_item
  FROM found_items
  WHERE id = v_claim.item_id AND deleted_at IS NULL
  FOR UPDATE;

  IF v_item.reported_by != v_actor THEN
    RAISE EXCEPTION 'NOT_ITEM_OWNER' USING ERRCODE = 'P0007';
  END IF;

  -- 2. Approve this claim
  UPDATE claims
  SET status = 'approved', resolved_at = now()
  WHERE id = p_claim_id;

  -- 3. Reject all other pending claims for the same item
  UPDATE claims
  SET status = 'rejected', resolved_at = now()
  WHERE item_id = v_claim.item_id
    AND id != p_claim_id
    AND status = 'pending';

  -- 4. Mark item resolved
  UPDATE found_items
  SET status = 'resolved', updated_at = now()
  WHERE id = v_claim.item_id;

  -- 5. Insert return record
  INSERT INTO returns (found_item_id, claim_id, returned_to, returned_by, notes)
  VALUES (v_claim.item_id, p_claim_id, v_claim.claimant_id, v_actor, p_notes)
  RETURNING id INTO v_return_id;

  -- 6a. Notify claimant: approved
  INSERT INTO notifications (user_id, type, title, body, payload)
  VALUES (
    v_claim.claimant_id,
    'claim_approved',
    'Your claim was approved',
    'You can now collect "' || v_item.title || '"',
    jsonb_build_object('claim_id', p_claim_id, 'item_id', v_claim.item_id)
  );

  -- 6b. Notify rejected claimants
  INSERT INTO notifications (user_id, type, title, body, payload)
  SELECT
    c.claimant_id,
    'claim_rejected',
    'Claim unsuccessful',
    '"' || v_item.title || '" has been claimed by someone else',
    jsonb_build_object('item_id', v_claim.item_id)
  FROM claims c
  WHERE c.item_id = v_claim.item_id
    AND c.id != p_claim_id
    AND c.status = 'rejected';

  RETURN jsonb_build_object(
    'return_id', v_return_id,
    'claim_id',  p_claim_id,
    'status',    'resolved'
  );
END;
$$;


-- ── E3: rpc_reject_claim ──────────────────────────────────────
-- Atomically reject a claim and re-open the item.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_reject_claim(
  p_claim_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := current_user_id();
  v_claim claims%ROWTYPE;
  v_item  found_items%ROWTYPE;
BEGIN
  SELECT * INTO v_claim
  FROM claims
  WHERE id = p_claim_id AND deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND OR v_claim.status != 'pending' THEN
    RAISE EXCEPTION 'CLAIM_NOT_PENDING' USING ERRCODE = 'P0006';
  END IF;

  SELECT * INTO v_item FROM found_items WHERE id = v_claim.item_id FOR UPDATE;

  IF v_item.reported_by != v_actor THEN
    RAISE EXCEPTION 'NOT_ITEM_OWNER' USING ERRCODE = 'P0007';
  END IF;

  UPDATE claims
  SET status = 'rejected', resolved_at = now()
  WHERE id = p_claim_id;

  -- Re-open item so it can receive new claims
  UPDATE found_items
  SET status = 'open', updated_at = now()
  WHERE id = v_claim.item_id;

  -- Notify claimant
  INSERT INTO notifications (user_id, type, title, body, payload)
  VALUES (
    v_claim.claimant_id,
    'claim_rejected',
    'Your claim was not approved',
    'The item reporter could not verify ownership of "' || v_item.title || '"',
    jsonb_build_object('claim_id', p_claim_id, 'item_id', v_claim.item_id)
  );

  RETURN jsonb_build_object('claim_id', p_claim_id, 'status', 'rejected');
END;
$$;


-- ── E4: rpc_increment_download ────────────────────────────────
-- Safe atomic download counter — avoids race on UPDATE.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION rpc_increment_download(p_resource_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  UPDATE resources
  SET download_count = download_count + 1
  WHERE id = p_resource_id
    AND deleted_at IS NULL;
$$;


-- ══════════════════════════════════════════════
--  F. INDEX ADDITIONS
-- ══════════════════════════════════════════════

-- Attendance percentage expression index (replaces 003 duplicate)
DROP INDEX IF EXISTS idx_courses_attendance_pct;
CREATE INDEX idx_courses_pct
  ON attendance_courses (
    semester_id,
    (CASE WHEN total_classes = 0 THEN 0
          ELSE ROUND((attended::numeric / total_classes) * 100) END) DESC
  );

-- Notification unread count (high-frequency badge query)
DROP INDEX IF EXISTS idx_notifications_unread;
CREATE INDEX idx_notifications_unread
  ON notifications (user_id)
  WHERE is_read = false AND deleted_at IS NULL;

-- Audit log: entity + action combo (admin investigation)
CREATE INDEX IF NOT EXISTS idx_audit_entity_action
  ON audit_logs (entity_type, action_type, created_at DESC);

-- Reports: pending triage queue
CREATE INDEX IF NOT EXISTS idx_reports_pending
  ON reports (created_at DESC)
  WHERE status = 'pending';

-- found_items: open items available for claiming (primary browse query)
CREATE INDEX IF NOT EXISTS idx_found_items_open
  ON found_items (created_at DESC)
  WHERE status = 'open' AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_lost_items_open
  ON lost_items (created_at DESC)
  WHERE status = 'open' AND deleted_at IS NULL;


-- ══════════════════════════════════════════════
--  G. CONSTRAINT REFINEMENTS
-- ══════════════════════════════════════════════

-- claims: the table-level UNIQUE on (item_id, status) conflicts with the
-- more precise partial unique index from 001. Drop the table constraint;
-- the partial index is the correct enforcement mechanism.
ALTER TABLE claims
  DROP CONSTRAINT IF EXISTS one_active_claim_per_item;

-- Add CHECK: resolved_at must be NULL when status = 'pending'
ALTER TABLE claims
  ADD CONSTRAINT claim_resolved_at_consistency CHECK (
    (status = 'pending'  AND resolved_at IS NULL) OR
    (status != 'pending' AND resolved_at IS NOT NULL)
  );

-- reports: resolved_at consistency
ALTER TABLE reports
  ADD CONSTRAINT report_resolved_at_consistency CHECK (
    (status = 'pending'  AND resolved_at IS NULL) OR
    (status != 'pending')                            -- admin may set resolved_at optionally
  );

-- attendance: prevent future-dated records
ALTER TABLE attendance_records
  ADD CONSTRAINT attendance_not_future CHECK (date <= CURRENT_DATE);


-- ══════════════════════════════════════════════
--  H. DATA-CONSISTENCY FK FIXES
-- ══════════════════════════════════════════════

-- returns.returned_to / returned_by: currently RESTRICT (default).
-- Set to SET NULL so a user account deletion doesn't orphan return history.
ALTER TABLE returns
  DROP CONSTRAINT IF EXISTS returns_returned_to_fkey,
  DROP CONSTRAINT IF EXISTS returns_returned_by_fkey;

ALTER TABLE returns
  ADD CONSTRAINT returns_returned_to_fkey
    FOREIGN KEY (returned_to) REFERENCES users(id) ON DELETE SET NULL,
  ADD CONSTRAINT returns_returned_by_fkey
    FOREIGN KEY (returned_by) REFERENCES users(id) ON DELETE SET NULL;

-- claims.claimant_id: SET NULL on user delete (preserve history)
ALTER TABLE claims
  DROP CONSTRAINT IF EXISTS claims_claimant_id_fkey;

ALTER TABLE claims
  ADD CONSTRAINT claims_claimant_id_fkey
    FOREIGN KEY (claimant_id) REFERENCES users(id) ON DELETE SET NULL;

-- notifications: CASCADE delete when user is deleted (no orphan noise)
-- Already CASCADE in 001; document intentional choice here.
-- reports.reporter_id: SET NULL (preserve report even if reporter deletes account)
ALTER TABLE reports
  DROP CONSTRAINT IF EXISTS reports_reporter_id_fkey;

ALTER TABLE reports
  ADD CONSTRAINT reports_reporter_id_fkey
    FOREIGN KEY (reporter_id) REFERENCES users(id) ON DELETE SET NULL;

-- audit_logs.user_id: already SET NULL in 005-C definition.

-- ── Final: revoke direct table access; all writes through RPCs ─
-- (Service role bypasses RLS, so this applies to authenticated role only)
REVOKE INSERT, UPDATE, DELETE ON claims   FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON returns  FROM authenticated;
-- Re-grant via the RPC functions (SECURITY DEFINER handles auth)
GRANT EXECUTE ON FUNCTION rpc_claim_item(uuid, text)  TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_approve_claim(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_reject_claim(uuid)       TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_increment_download(uuid) TO authenticated;