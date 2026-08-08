-- Runs once, on first start, and only when the data directory is empty.
--
-- This is not a migration system. A real deployment needs one; see
-- ARCHITECTURE.md for why that is deliberately out of scope here.

CREATE TABLE IF NOT EXISTS items (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       TEXT        NOT NULL CHECK (length(trim(name)) > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The API lists newest-first; without this the ORDER BY is a sequential scan
-- once the table is non-trivial.
CREATE INDEX IF NOT EXISTS items_id_desc_idx ON items (id DESC);
