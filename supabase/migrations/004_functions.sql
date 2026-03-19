-- =============================================================
--  UniHub  ·  Migration 004  ·  Storage, Realtime, Cron, Seed
-- =============================================================


-- ─────────────────────────────────────────────
--  Supabase Storage buckets
--  Run via Supabase Dashboard OR supabase CLI:
--    supabase storage create item-images --public false
--  The SQL below registers the bucket config in
--  storage.buckets so it can be referenced in RLS.
-- ─────────────────────────────────────────────

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  (
    'item-images',
    'item-images',
    false,                          -- signed URLs only
    5242880,                        -- 5 MB
    ARRAY['image/webp','image/jpeg','image/png']
  ),
  (
    'resource-files',
    'resource-files',
    false,
    52428800,                       -- 50 MB
    ARRAY['application/pdf']
  ),
  (
    'thumbnails',
    'thumbnails',
    true,                           -- public CDN thumbnails
    524288,                         -- 512 KB
    ARRAY['image/webp']
  )
ON CONFLICT (id) DO NOTHING;


-- Storage RLS: item-images
-- Owner can upload; any authenticated user can read (via signed URL generation)
CREATE POLICY "item_images_owner_upload"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'item-images'
    AND auth.role() = 'authenticated'
  );

CREATE POLICY "item_images_auth_read"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'item-images'
    AND auth.role() = 'authenticated'
  );

CREATE POLICY "item_images_owner_delete"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'item-images'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Storage RLS: resource-files (same pattern)
CREATE POLICY "resource_files_owner_upload"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'resource-files'
    AND auth.role() = 'authenticated'
  );

CREATE POLICY "resource_files_auth_read"
  ON storage.objects FOR SELECT
  USING (
    bucket_id = 'resource-files'
    AND auth.role() = 'authenticated'
  );

CREATE POLICY "resource_files_owner_delete"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'resource-files'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Storage RLS: thumbnails (public bucket — no read policy needed)
CREATE POLICY "thumbnails_owner_upload"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'thumbnails'
    AND auth.role() = 'authenticated'
  );


-- ─────────────────────────────────────────────
--  Supabase Realtime
--  Enable Realtime publication for live notifications.
-- ─────────────────────────────────────────────
BEGIN;
  DROP PUBLICATION IF EXISTS supabase_realtime CASCADE;
  CREATE PUBLICATION supabase_realtime FOR TABLE
    notifications,      -- live notification feed
    found_items,        -- status changes (open → claimed → resolved)
    lost_items,         -- status changes
    claims;             -- claim status updates for item owner
COMMIT;


-- ─────────────────────────────────────────────
--  Cron: expire stale open items (pg_cron)
--  Requires pg_cron extension (enabled in Supabase dashboard).
-- ─────────────────────────────────────────────
-- Items open for > 30 days are automatically expired.
-- The cron runs daily at 02:00 UTC.

-- SELECT cron.schedule(
--   'expire-stale-items',
--   '0 2 * * *',
--   $$
--     UPDATE lost_items
--     SET status = 'expired', updated_at = now()
--     WHERE status = 'open'
--       AND created_at < now() - INTERVAL '30 days';

--     UPDATE found_items
--     SET status = 'expired', updated_at = now()
--     WHERE status = 'open'
--       AND created_at < now() - INTERVAL '30 days';
--   $$
-- );

-- Cron: prune old read notifications (keep last 90 days)
-- SELECT cron.schedule(
--   'prune-old-notifications',
--   '0 3 * * 0',   -- weekly, Sunday 03:00 UTC
--   $$
--     DELETE FROM notifications
--     WHERE is_read = true
--       AND created_at < now() - INTERVAL '90 days';
--   $$
-- );


-- ─────────────────────────────────────────────
--  Seed: item categories
--  Referenced as a CHECK list in application code
--  (not a FK table — keeps schema lean).
-- ─────────────────────────────────────────────
CREATE TABLE item_categories (
  slug  text PRIMARY KEY,
  label text NOT NULL
);

INSERT INTO item_categories (slug, label) VALUES
  ('electronics',   'Electronics'),
  ('clothing',      'Clothing & Accessories'),
  ('stationery',    'Stationery & Books'),
  ('id_documents',  'ID / Documents'),
  ('keys',          'Keys'),
  ('bags',          'Bags & Wallets'),
  ('sports',        'Sports Equipment'),
  ('food',          'Food / Water Bottle'),
  ('jewellery',     'Jewellery'),
  ('other',         'Other');

-- Public read for categories (no auth required)
ALTER TABLE item_categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "categories_public_read"
  ON item_categories FOR SELECT
  USING (true);


-- ─────────────────────────────────────────────
--  Seed: resource subjects
-- ─────────────────────────────────────────────
CREATE TABLE resource_subjects (
  slug  text PRIMARY KEY,
  label text NOT NULL
);

INSERT INTO resource_subjects (slug, label) VALUES
  ('mathematics',       'Mathematics'),
  ('physics',           'Physics'),
  ('chemistry',         'Chemistry'),
  ('biology',           'Biology'),
  ('computer_science',  'Computer Science'),
  ('electrical',        'Electrical Engineering'),
  ('mechanical',        'Mechanical Engineering'),
  ('civil',             'Civil Engineering'),
  ('economics',         'Economics'),
  ('management',        'Management'),
  ('english',           'English'),
  ('other',             'Other');

ALTER TABLE resource_subjects ENABLE ROW LEVEL SECURITY;
CREATE POLICY "subjects_public_read"
  ON resource_subjects FOR SELECT
  USING (true);