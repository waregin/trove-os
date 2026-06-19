# trove-os

**Trove** is a unified **collections + home inventory** system. One place for books, video
games, plushies, LEGO, films, Corelle dishware, board games, puzzles, miscellaneous
collectibles, *and* general home-inventory items (appliances, tools, electronics) — with a
wishlist, barcode/ISBN capture, and an insurance-friendly value export.

> "Collections OS / Home Inventory OS — they'll be very similar, maybe the same thing?"
> → Yes. It's the same thing, and it's Trove.

This repo is **self-describing**: the canonical design lives here in this README and in
[`trove_schema.sql`](./trove_schema.sql). [`REQUIREMENTS.md`](./REQUIREMENTS.md) is retained as
historical context, but **the schema and the sibling [`waregin/CollectionsScanner`](https://github.com/waregin/CollectionsScanner)
design docs win** wherever they disagree with it.

---

## ⏱️ Context: there's a move coming

A home sale could close with **as little as 30 days to vacate** once a buyer signs, and packing
(with inventory lists) is already underway. **Scanning items into boxes while packing is a
one-time opportunity** — once a box is taped and stacked, that chance is gone. So the guiding
principle for near-term work is **move-useful over elegant**, and the near-term priority is the
*capture path*, not the full app. See [Phase-1 scope](#phase-1-scope-capture-first) below.

---

## Architecture at a glance

- **PostgreSQL** schema (complete — see [`trove_schema.sql`](./trove_schema.sql)).
- **Multi-tenant from day one** — `user_id` on every table; auth lives in a separate auth schema
  (Supabase/Auth0-compatible). `users` is a stub for that integration.
- **API-first.** Planned progression: local web app → server-deployed → mobile → potential SaaS.
- **Type-specific metadata in extension tables, not JSON blobs.**
- **Images stored externally** (S3/R2); the DB stores URLs only.
- `ownership_status` and `physical_location` are **separate concepts** (you can own something
  that's lent out, lost, or digital).
- **Barcode/ISBN/UPC capture** feeds Trove. During the move this is handled by a thin, offline
  capture client (see below); server-side, repeated scans are cached in `external_id_cache`.

### Two data paradigms

| Paradigm | Table(s) | Use for |
|---|---|---|
| **Individual items** — one row per discrete object | `items` + `item_*` extension tables | books, games, plushies, LEGO, films, board games, puzzles, home inventory |
| **Quantity sets** — one row per pattern + item-type, tracked by count | `quantity_collection_types` → `quantity_collection_groups` → `quantity_collection_items` | Corelle dishware, trading-card sets, anything counted rather than individually catalogued |

Plus: `wishlist_entries` (wishlist, optionally wrapping a catalogued item),
`external_id_cache` (barcode → metadata cache), `item_audit_log` (change history),
`storage_locations` (reusable, hierarchical named locations).

### Collection types

`collection_type` is free text on `items`, documented (not enum-enforced) so new types are cheap
to add. **Values are plural**, and the rule is:

> the extension table for a type is `'item_' || collection_type`
> (e.g. `print_books` → `item_print_books`, `films` → `item_films`).

| `collection_type` | Extension table | Notes |
|---|---|---|
| `print_books` | `item_print_books` | author, isbn, ddc (NUMERIC), publisher, edition, read status |
| `ebooks` | `item_ebooks` | file path/format, isbn |
| `films` | `item_films` | year, format, file path, watched status |
| `games` | `item_games` | platform, storefront, play status (video games) |
| `lego` | `item_lego` | set number, theme, piece count, built/displayed |
| `plushies` | `item_plushies` | brand, species, size |
| `nicky_nacks` | `item_nicky_nacks` | misc collectibles; no extra columns (typed anchor) |
| `home_inventory` | `item_home_inventory` | manufacturer, serial, warranty, receipt (insurance) |
| **`board_games`** | *(none yet)* | **new 2026-06-18** — valid type, no extension table for now |
| **`puzzles`** | *(none yet)* | **new 2026-06-18** — valid type, no extension table for now |

`board_games` and `puzzles` were added as their own first-class types (deliberately **not** folded
into `nicky_nacks`). They currently have **no extension table** — core `items` fields are enough to
capture them during the move. Candidate type-specific fields (board games: player count, play time,
designer, BGG id; puzzles: piece count, brand, dimensions, completed/missing-pieces) are deferred to
a post-move issue.

---

## The capture workflow (move-time)

The barcode-capture client is specified in **CollectionsScanner** and **built here in trove-os**
(it ports the ISBN-lookup prototype from `CollectionsScanner/main.py`). It is deliberately a *thin,
offline, crash-safe* tool:

```
scan (offline)  →  append to queue.jsonl  →  export.csv  →  Trove importer  →  items + storage_locations
```

- **Capture does zero network at scan time.** Each scanned code is appended to `queue.jsonl` and
  flushed immediately — works in airplane mode, survives Ctrl-C, resumes the active box on restart.
- `BOX <label>` / `TYPE <collection>` / `DONE` commands batch scans by box and collection type.
- Title/UPC resolution is **optional and post-move** — Trove resolves codes server-side via
  `external_id_cache`, so capture never has to block on a lookup.

`queue.jsonl` record (one JSON object per line):

```json
{"code":"9780553213113","code_type":"isbn","collection":"print_books","box":"kitchen-12","scanned_at":"2026-06-18T17:50:00Z","status":"raw","title":null,"author":null,"ddc":null}
```

`collection` values match Trove `collection_type` exactly (plural — see table above) so export
needs **no remapping**.

### How a box label becomes a location — **DECIDED**

> A captured `box` label maps to `storage_locations` by **importer-side upsert**.

The capture client stays **UUID-free and offline**: it only ever writes a plain-text box label. The
**importer** resolves that label to a `storage_location_id` by upserting a top-level
`storage_locations` row on `(user_id, name)` and reading back its `id`. A partial unique index
(`storage_locations_user_name_toplevel_uniq`, `WHERE parent_id IS NULL`) makes this **idempotent**
across replayed imports, while still allowing nested locations to reuse a name under a different
parent. *(This confirms the recommended default in CollectionsScanner's `trove-import-mapping.md`;
implemented in [`trove_schema.sql`](./trove_schema.sql).)*

### Import mapping (export.csv → schema)

1. Insert an `items` row (universal fields: `title`, `collection_type`, `ownership_status` default
   `owned`, `location_notes`, etc.).
2. Resolve `box` → `storage_location_id` via the upsert above.
3. Populate the extension table for the type (`'item_' || collection_type`) when one exists.
   - `print_books`: `isbn`, and `ddc` **coerced to NUMERIC** (never a string).
   - raw `upc` / `igdb` / `lego_set` codes go to `external_id_cache` for server-side resolution.
4. **Include every queue row regardless of `status`** — even unresolved rows preserve the
   irreplaceable `code` + `box`, which is the whole point of capturing during the move.

---

## Phase-1 scope: **capture-first**

Given the move date, phase 1 is **capture-first**, not app-first. Rationale:

- Scanning items into boxes while packing is a **one-time, time-boxed opportunity**; the full app
  is not. If we build the app first and miss the packing window, the inventory data is gone for good.
- The capture client is small, offline, and portable (runs today on Zorin with `requests` /
  stdlib). The web app + auth + UI is weeks of work with no move-day payoff.
- Trove can ingest the captured queue at any later, calmer date — the schema and importer are the
  durable half; the queue is a **replayable fixture**.

**Order of work (most to least move-critical):**

1. **Capture loop** (offline, crash-safe, box-batched) ← *the single most move-critical thing.*
2. **Export** `queue.jsonl` → `export.csv`.
3. **Run on Zorin** today: deps, quickstart, scanner sanity check.
4. **Trove importer** (`export.csv` → `items` + extensions + `storage_locations`).
5. **Legacy spreadsheet import** (below).

Post-move / optional: resolve-later enrichment pass (ISBN→title/author/ddc), non-ISBN/UPC
resolution, `board_games`/`puzzles` extension tables.

> App-first only makes sense if the move slips materially (months out). If the timeline changes,
> say so and we re-order.

---

## Legacy data: collections spreadsheet import

A long-maintained **Google Sheets** workbook (formerly a Microsoft Access DB) is the legacy source
of truth for the existing collections (notably books). Plan:

1. **Inventory the tabs/columns.** One sheet/tab per collection (books, games, plushies, LEGO,
   Corelle, films, …). Capture each tab's real column names and a few sample rows before mapping.
2. **Per-tab column → schema mapping.** For each tab, decide its `collection_type` and map columns
   to `items` + the right `item_*` extension. Mirror the capture import rules: `ddc` → NUMERIC,
   `isbn` kept as text (preserve leading zeros), value/currency for insurance, `box`/shelf text →
   `storage_locations` upsert by name (same idempotent path as capture).
3. **Corelle / counted sets → quantity paradigm**, not `items`: pattern → `quantity_collection_groups`,
   per-item-type counts (have/want) → `quantity_collection_items`.
4. **Export each tab to CSV** and feed the *same Trove importer* used for capture — one importer,
   two front doors (CSV from Sheets, CSV from the scanner). Reuse the storage-location upsert and the
   per-type extension logic so there's a single code path to test.
5. **Idempotent + replayable.** Run against a throwaway DB first, eyeball, then load for real.
   Keep a natural key per row (isbn / set number / title+author) to allow re-runs without dupes.
6. **Sequencing vs. the move:** the spreadsheet isn't going anywhere — it's not the one-time
   opportunity the *physical* scan is. So it lands **after** the capture path is working, but its
   importer is shared, so building the capture importer mostly builds this too.

This is tracked as a move-related issue (see [Roadmap / issues](#roadmap--issues)).

---

## Reconciliation notes & flagged contradictions

Per instruction, the **schema** and **CollectionsScanner docs** win over `REQUIREMENTS.md`. Where
those two authoritative sources disagreed *with each other*, the resolution is flagged here.

1. **Singular vs. plural `collection_type` — RESOLVED to plural.** The schema comment originally
   documented singular values (`print_book`, `film`, `game`…), but every extension **table** is
   plural (`item_print_books`, `item_films`, `item_games`…) and the capture spec lists plural values
   with an explicit "no remap on import" guarantee. Plural wins on both counts; the schema comment is
   updated, and the rule is now `'item_' || collection_type`.
2. **`board_games` / `puzzles` are their own types** — *not* folded into `nicky_nacks` (per the
   capture spec's collection list and this task). Added as valid `collection_type` values with no
   extension table yet.
3. **Box label → `storage_locations`** — the one open decision in `trove-import-mapping.md`,
   resolved to *importer-side upsert by name* (see above).
4. **"Card games" (from REQUIREMENTS / TickTick) has no dedicated type.** Treat physical card games
   as `board_games`; treat *collectible/trading cards* (Pokémon, etc.) as the **quantity-set**
   paradigm, like Corelle. Flagged, not yet schema-encoded.
5. **Popsockets / minifigures (from TickTick)** → `nicky_nacks` (misc collectibles). No new type.
6. **Capture-side title/UPC resolution is optional/post-move** (not a phase-1 blocker), because
   `external_id_cache` resolves codes server-side. REQUIREMENTS framed lookup as core to scanning;
   the newer capture decision de-prioritizes it. Capture decision wins.

---

## Roadmap / issues

Priorities mirror CollectionsScanner: **capture + import are move-critical**; capture-side
title/UPC resolution is optional/post-move. The single most move-critical issue — the **offline
capture loop** — is labeled `next`. See the repo's
[Issues](https://github.com/waregin/trove-os/issues) tab.

| Priority | Work |
|---|---|
| `next` / move-critical | Offline-first, crash-safe **capture loop** (port `main.py`, box batching) |
| move-critical | **Export** `queue.jsonl` → `export.csv` |
| move-critical | **Run on Zorin**: deps, quickstart, scanner sanity check |
| move-critical | **Trove importer**: `export.csv` → `items` + extensions + `storage_locations` upsert |
| move-related | **Legacy spreadsheet import** (Google Sheets → Trove, shared importer) |
| post-move / optional | Resolve-later enrichment pass (ISBN → title/author/ddc) |
| post-move / optional | Non-ISBN / UPC resolution (games, films, etc.) |
| post-move / backlog | `item_board_games` / `item_puzzles` extension tables, if/when needed |

---

## Repo layout

```
trove-os/
├── README.md            ← you are here (canonical design)
├── REQUIREMENTS.md      ← historical context (superseded by README + schema)
└── trove_schema.sql     ← complete PostgreSQL schema
```
