-- =============================================================================
-- TROVE - Personal Inventory & Collections Database Schema
-- =============================================================================
-- Two paradigms:
--   1. INDIVIDUAL ITEMS  — one row per discrete object (books, games, plushies…)
--   2. QUANTITY SETS     — one row per pattern+item-type combo, tracked by count
--                          (Corelle dishware, trading cards, etc.)
--
-- Core design decisions:
--   - Multi-tenant from day one (user_id on every table)
--   - Auth lives in a separate auth schema (Supabase/Auth0 compatible)
--   - Type-specific metadata in extension tables, not JSON blobs
--   - Images stored externally (S3/R2); DB stores URLs only
--   - ownership_status and physical_location are separate concepts
-- =============================================================================


-- ---------------------------------------------------------------------------
-- EXTENSIONS
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm"; -- for fast fuzzy title search


-- =============================================================================
-- SHARED LOOKUPS
-- =============================================================================

CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email         TEXT NOT NULL UNIQUE,
    display_name  TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE users IS 'One row per Trove account. Stub for auth integration.';


CREATE TABLE storage_locations (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,           -- "dishes cupboard", "LEGO Storage Tote 1"
    parent_id   UUID REFERENCES storage_locations(id),  -- supports nested locations
    notes       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE storage_locations IS
    'Reusable named locations. Hierarchical (parent_id) so you can model '
    '"house > office > shelf 2" or "storage unit > tote marked fragile".';

CREATE INDEX ON storage_locations(user_id);
CREATE INDEX ON storage_locations(parent_id);

-- Box-label resolution (decided 2026-06-18): the CollectionsScanner capture client stays UUID-free
-- and offline — it records only a plain-text box label per scan. The Trove importer resolves that
-- label to storage_location_id by UPSERTING a top-level storage_locations row on (user_id, name).
-- This partial unique index makes that upsert idempotent across repeated/replayed imports while
-- still allowing nested locations to reuse a name under different parents (parent_id IS NOT NULL).
--   importer: INSERT ... (user_id, name) VALUES (...) ON CONFLICT (user_id, name)
--             WHERE parent_id IS NULL DO UPDATE SET name = EXCLUDED.name RETURNING id;
CREATE UNIQUE INDEX storage_locations_user_name_toplevel_uniq
    ON storage_locations(user_id, name) WHERE parent_id IS NULL;


-- =============================================================================
-- PARADIGM 1: INDIVIDUAL ITEMS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Core item record — fields shared by ALL individual-item collections
-- ---------------------------------------------------------------------------

CREATE TYPE ownership_status AS ENUM (
    'owned',        -- in your possession
    'wanted',       -- on your wish list
    'lent_out',     -- you own it but someone else has it
    'ordered',      -- purchased, not yet received
    'lost',         -- whereabouts unknown
    'given_away',   -- intentionally transferred to someone else
    'sold',         -- sold
    'digital'       -- owned digitally, no physical location
);

CREATE TABLE items (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- Identity
    collection_type     TEXT NOT NULL,  -- 'print_books' | 'ebooks' | 'films' | 'games'
                                        --   | 'lego' | 'plushies' | 'nicky_nacks'
                                        --   | 'home_inventory' | 'board_games' | 'puzzles'
                                        -- Values are PLURAL: the extension table for a type is
                                        --   ('item_' || collection_type), e.g. 'print_books' →
                                        --   item_print_books, 'films' → item_films. This also
                                        --   matches the CollectionsScanner capture client's
                                        --   `collection` field, so export → import needs no remap.
                                        -- 'board_games' and 'puzzles' (added 2026-06-18) are valid
                                        --   collection types with NO extension table yet — the core
                                        --   item fields suffice for move-time capture. Add
                                        --   item_board_games / item_puzzles later if/when
                                        --   type-specific fields are needed.
    title               TEXT NOT NULL,
    subtitle            TEXT,
    series_title        TEXT,
    series_position     TEXT,           -- e.g. "3", "3.5", "Book 2 of 5"

    -- Ownership
    ownership_status    ownership_status NOT NULL DEFAULT 'owned',
    lent_to             TEXT,           -- name of person if status = lent_out
    acquisition_source  TEXT,           -- "Steam", "Humble Bundle", "Thrift store"
    approximate_value   NUMERIC(10,2),  -- for insurance export
    currency            CHAR(3) DEFAULT 'USD',

    -- Location (physical)
    storage_location_id UUID REFERENCES storage_locations(id),
    location_notes      TEXT,           -- free-text override / detail

    -- Media
    primary_image_url   TEXT,           -- main photo
    -- additional images live in item_images

    -- Meta
    notes               TEXT,
    tags                TEXT[],         -- freeform user tags
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON COLUMN items.collection_type IS
    'Determines which extension table holds type-specific attributes.';
COMMENT ON COLUMN items.series_position IS
    'Stored as text to handle "3.5", "Part II", "Volume 4" etc.';

CREATE INDEX ON items(user_id);
CREATE INDEX ON items(user_id, collection_type);
CREATE INDEX ON items(user_id, ownership_status);
CREATE INDEX ON items(storage_location_id);
-- Trigram index for fast fuzzy title search across all collections
CREATE INDEX ON items USING gin(title gin_trgm_ops);


CREATE TABLE item_images (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    item_id     UUID NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    url         TEXT NOT NULL,
    caption     TEXT,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON item_images(item_id);


-- ---------------------------------------------------------------------------
-- EXTENSION: Print Books
-- ---------------------------------------------------------------------------
CREATE TABLE item_print_books (
    item_id     UUID PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    author      TEXT NOT NULL,
    isbn        TEXT,               -- ISBN-13 preferred
    ddc         NUMERIC(10,3),      -- Dewey Decimal, e.g. 550.0, 567.9
    publisher   TEXT,
    pub_year    SMALLINT,
    edition     TEXT,               -- "2nd edition", "Collector's Edition", etc.
    is_signed   BOOLEAN NOT NULL DEFAULT FALSE,
    is_special_edition BOOLEAN NOT NULL DEFAULT FALSE,
    read_status TEXT,               -- 'unread' | 'reading' | 'read' | 'abandoned'
    date_read   DATE
);
COMMENT ON COLUMN item_print_books.isbn IS 'Store as text to preserve leading zeros and hyphens.';
CREATE INDEX ON item_print_books(isbn);


-- ---------------------------------------------------------------------------
-- EXTENSION: Ebooks
-- ---------------------------------------------------------------------------
CREATE TABLE item_ebooks (
    item_id             UUID PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    author_publisher    TEXT,
    file_path           TEXT,       -- e.g. "Books/Iron Circus Comics/Atomic Robo"
    file_format         TEXT,       -- 'epub' | 'pdf' | 'mobi' | 'cbz' | etc.
    isbn                TEXT,
    read_status         TEXT        -- 'unread' | 'reading' | 'read' | 'abandoned'
);
CREATE INDEX ON item_ebooks(isbn);


-- ---------------------------------------------------------------------------
-- EXTENSION: Film
-- ---------------------------------------------------------------------------
CREATE TABLE item_films (
    item_id         UUID PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    year            SMALLINT,
    format          TEXT,   -- 'Blu-Ray' | 'DVD' | 'ISO' | 'mp4' | 'AVI' | 'VHS'
    file_path       TEXT,   -- for digital/ISO copies, e.g. "DAS0NNW1.iso"
    watched_status  TEXT    -- 'unwatched' | 'watching' | 'watched'
);


-- ---------------------------------------------------------------------------
-- EXTENSION: Video Games
-- ---------------------------------------------------------------------------
CREATE TABLE item_games (
    item_id         UUID PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    platform        TEXT,   -- 'PC' | 'Switch' | '3DS' | 'DS' | 'N64' | 'GBA' | etc.
    storefront      TEXT,   -- 'Steam' | 'GOG' | 'Origin' | 'Nintendo eShop' | NULL (physical)
    play_status     TEXT    -- 'unplayed' | 'playing' | 'completed' | 'abandoned'
);
COMMENT ON COLUMN item_games.storefront IS
    'Where to launch the game if digital. NULL = physical cartridge/disc.';
CREATE INDEX ON item_games(platform);
CREATE INDEX ON item_games(storefront);


-- ---------------------------------------------------------------------------
-- EXTENSION: LEGO
-- ---------------------------------------------------------------------------
CREATE TABLE item_lego (
    item_id         UUID PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    set_number      TEXT,           -- LEGO set ID, e.g. "10290"
    theme           TEXT,           -- "Icons", "Botanicals", "Ideas", etc.
    piece_count     INTEGER,
    is_built        BOOLEAN NOT NULL DEFAULT FALSE,
    is_displayed    BOOLEAN NOT NULL DEFAULT FALSE
);
COMMENT ON COLUMN item_lego.set_number IS 'LEGO official set number, stored as text for sets like "850705".';
CREATE INDEX ON item_lego(set_number);
CREATE INDEX ON item_lego(theme);


-- ---------------------------------------------------------------------------
-- EXTENSION: Plushies
-- ---------------------------------------------------------------------------
CREATE TABLE item_plushies (
    item_id         UUID PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    brand           TEXT,           -- "Squishable", "Squishmallow", "GUND", etc.
    species_type    TEXT,           -- "corgi", "chinese dragon", "spotted seal"
    size_value      TEXT,           -- stored exactly as given: "regular", "16\"", "3 lbs"
    size_system     TEXT            -- 'brand_named' | 'inches' | 'weight' | 'other'
                                    -- helps display/filter without forcing normalization
);
CREATE INDEX ON item_plushies(brand);


-- ---------------------------------------------------------------------------
-- EXTENSION: Nicky Nacks (miscellaneous collectibles)
-- No extension columns beyond core items — description lives in items.title,
-- images in item_images. This table exists as a typed anchor if needed later.
-- ---------------------------------------------------------------------------
CREATE TABLE item_nicky_nacks (
    item_id     UUID PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE
);


-- ---------------------------------------------------------------------------
-- EXTENSION: Home Inventory
-- For non-collection owned items: appliances, hardware, tools, monitors, etc.
-- ---------------------------------------------------------------------------
CREATE TABLE item_home_inventory (
    item_id         UUID PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
    manufacturer    TEXT,
    model_number    TEXT,
    serial_number   TEXT,
    purchase_date   DATE,
    purchase_price  NUMERIC(10,2),
    warranty_expiry DATE,
    receipt_url     TEXT            -- scan/photo of receipt for insurance
);
CREATE INDEX ON item_home_inventory(serial_number);


-- =============================================================================
-- PARADIGM 2: QUANTITY SETS
-- For collections tracked by count per item-type, not individual objects.
-- Pattern: Corelle dishware, trading card sets, etc.
-- =============================================================================

CREATE TABLE quantity_collection_types (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,      -- "Corelle", "Pokémon Cards"
    notes       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON quantity_collection_types(user_id);


CREATE TABLE quantity_collection_groups (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    collection_id   UUID NOT NULL REFERENCES quantity_collection_types(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,  -- Pattern name, e.g. "Berries and Cherries"
    image_url       TEXT,
    notes           TEXT,
    sort_order      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ON quantity_collection_groups(collection_id);


CREATE TABLE quantity_collection_items (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    group_id        UUID NOT NULL REFERENCES quantity_collection_groups(id) ON DELETE CASCADE,
    item_type       TEXT NOT NULL,  -- "dinner plate", "cereal bowl (18oz)", etc.
    quantity_have   INTEGER NOT NULL DEFAULT 0,
    quantity_want   INTEGER,        -- NULL = no target; 0 = don't want
    notes           TEXT,           -- "no lunch plate exists", "haven't seen yet"
    storage_location_id UUID REFERENCES storage_locations(id),
    location_notes  TEXT
);
CREATE INDEX ON quantity_collection_items(group_id);

COMMENT ON TABLE quantity_collection_items IS
    'Each row is a pattern+item-type combo with counts. '
    'E.g. Berries and Cherries / dinner plate / have: 8 / want: 8.';


-- =============================================================================
-- WISHLIST
-- Can reference an existing item (ownership_status = wanted)
-- OR be a free-standing entry not yet in any collection.
-- =============================================================================

CREATE TABLE wishlist_entries (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- Link to an existing item if it's already catalogued
    item_id             UUID REFERENCES items(id) ON DELETE SET NULL,

    -- Standalone fields (used when item_id is NULL)
    title               TEXT,
    url                 TEXT,           -- product page on any shopping site
    image_url           TEXT,
    price               NUMERIC(10,2),
    currency            CHAR(3) DEFAULT 'USD',
    notes               TEXT,
    priority            SMALLINT DEFAULT 3, -- 1=high, 2=medium, 3=low

    is_fulfilled        BOOLEAN NOT NULL DEFAULT FALSE,
    fulfilled_at        TIMESTAMPTZ,    -- set when purchased/received

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT wishlist_has_reference CHECK (
        item_id IS NOT NULL OR title IS NOT NULL
    )
);
CREATE INDEX ON wishlist_entries(user_id, is_fulfilled);
CREATE INDEX ON wishlist_entries(item_id);

COMMENT ON TABLE wishlist_entries IS
    'A wishlist entry can be a thin wrapper around an already-catalogued item '
    '(item_id set, ownership_status = wanted) or a freestanding entry with a '
    'URL and price before it has been fully catalogued.';


-- =============================================================================
-- BARCODE / EXTERNAL ID LOOKUP CACHE
-- Stores results from ISBN/UPC/IGDB lookups so repeated scans don't re-hit APIs
-- =============================================================================

CREATE TABLE external_id_cache (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    id_type         TEXT NOT NULL,      -- 'isbn' | 'upc' | 'igdb' | 'lego_set'
    external_id     TEXT NOT NULL,
    source          TEXT NOT NULL,      -- 'open_library' | 'igdb' | 'upc_item_db'
    payload         JSONB NOT NULL,     -- raw API response
    fetched_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(id_type, external_id, source)
);
CREATE INDEX ON external_id_cache(id_type, external_id);

COMMENT ON TABLE external_id_cache IS
    'Cache for barcode scan → metadata lookups. '
    'Avoids redundant API calls and works offline after first scan.';


-- =============================================================================
-- AUDIT / CHANGE LOG (optional for phase 1, useful for phase 4 SaaS)
-- =============================================================================

CREATE TABLE item_audit_log (
    id          BIGSERIAL PRIMARY KEY,
    item_id     UUID NOT NULL,          -- no FK so deleted items are preserved
    user_id     UUID NOT NULL,
    action      TEXT NOT NULL,          -- 'created' | 'updated' | 'deleted'
    changed_fields JSONB,               -- {field: [old_val, new_val]}
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ON item_audit_log(item_id);
CREATE INDEX ON item_audit_log(user_id, created_at DESC);


-- =============================================================================
-- UPDATED_AT TRIGGER (apply to all tables with updated_at)
-- =============================================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER items_updated_at
    BEFORE UPDATE ON items
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER wishlist_updated_at
    BEFORE UPDATE ON wishlist_entries
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
