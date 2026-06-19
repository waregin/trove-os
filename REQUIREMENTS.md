# trove-os — Requirements & Context

> **Status (2026-06-19): merged into [`README.md`](./README.md), which is now canonical.**
> This file is kept for history. Where it conflicts with the README, the schema, or the
> CollectionsScanner design docs, those win.

> Known immediate task: **grab the architecture document and put it in the README.** Trove is among the better-specified modules — the architecture doc and completed PostgreSQL schema win over anything here.

## Purpose
Unified collections + home inventory tool ("Collections OS / Home Inventory OS — they'll be very similar, maybe same thing?" → answer: yes, this is the same thing, and it's Trove).

## Known design (verify against arch doc)
- Domains: books, video games, plushies, LEGO, Corelle dishware, films, misc collectibles + general home inventory
- PostgreSQL schema completed
- Wishlist system; barcode scanner integration via ISBN/UPC lookup (hardware scanner owned)
- API-first; multi-tenancy from phase 1; progression: local web app → server-deployed → mobile → potential SaaS
- Long-maintained Google Sheets (formerly Access DB) collections spreadsheet is the legacy data source to import

## Move-driven urgency
**Update:** the sale could close with as little as 30 days to vacate; packing (with inventory lists) is already underway as Reggie's primary personal focus. Capture-first is now the strong default unless the session finds a blocker.
The home move makes Trove (or its capture path) time-sensitive: inventorying boxes while packing is a one-time opportunity. See CollectionsScanner-REQUIREMENTS.md — recommended that a minimal capture flow (scan → box label → queue) be prioritized over the full app if the move date is near.

## Context from TickTick
- "add to collections inventory": board/card games, jigsaw puzzles, popsockets, minifigures (all w/ photos) — LEGO done
- "organize book related database tables (currently spreadsheets)" [RegNextTask]
- Plushy collection reduction + photo cataloging goals

## First session objectives
1. Locate architecture doc + schema; merge into README; reconcile
2. Decide phase 1 scope **explicitly against the move date** — capture-first vs app-first
3. Define spreadsheet import plan for legacy data
4. Open issues; label one `next`
