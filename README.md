# Seamless Menu Accuracy & Retention

Measures how accurately the **SCC (Salesforce Content Creator)** auto-generated draft menu matches what a vendor actually goes live with, and whether the draft was retained in Salesforce.

---

## Context

When a new restaurant vendor onboards via the Seamless Market flow, the SCC system auto-generates a draft menu. This project answers:

> *"How good was that auto-generated draft — and did the vendor keep it?"*

Three scores are produced per vendor. These can be aggregated to a brand or country level using item-count weighted averages.

---

## Scoring Model

### Score 1 — Total Product Completeness (TPC)

**Formula:** `anticipated_items / total_live_items × 100`

- **Numerator (anticipated):** Live primary items that the draft correctly generated — either as a primary item (`matched`) or as a nested option (`live_only_in_draft_as_option`)
- **Denominator:** All live primary items, including items the draft never knew about (`live_only`)
- `live_only` items inflate the denominator → reduce TPC

**Example — vendor `wu5t` / grid `HTA5NP` / [live menu](https://portal.foodpanda.com/pv2/ph/p/backoffice/vendors/wu5t/menus):**
> Draft generated 15 primary items. Live menu had 21. 14 were exact matches. 7 live items were `live_only` (vendor added them manually). TPC = 14/21 = **66.7%**

**Item status reference:**

| `match_status` | TPC | Meaning |
|---|---|---|
| `matched` | ✓ numerator | Draft primary item found in live primary menu |
| `live_only_in_draft_as_option` | ✓ numerator | Live standalone item was generated as a nested draft option |
| `draft_item_as_live_option` | success, not in formula | Draft primary became a live choice group option |
| `draft_only` | excluded | Draft over-generated; item not in live anywhere |
| `live_only` | ✗ denominator only | Vendor added an item the draft had no knowledge of |

**Example — `live_only_in_draft_as_option` (vendor `wu5t` / [live menu](https://portal.foodpanda.com/pv2/ph/p/backoffice/vendors/wu5t/menus)):**
> SCC generated "Wings" with nested flavor options (Buffalo, Cheese, Soy Garlic, Salted Egg, Teriyaki). The vendor removed "Wings" as a standalone item but listed the flavors as individual live products. These show as `live_only_in_draft_as_option` with `draft_option_parent = wings` — they count toward TPC because the draft anticipated them.

**Example — TPC formula with live_only:**
> Draft: 8 items. Live: 10 items. All 8 draft items match. TPC = 8/10 = **80%**. The 2 extra live items the vendor added (`live_only`) inflate the denominator and reduce the score from 100%.

---

### Score 2 — Description Accuracy (DA)

**Formula:** `AVG(desc_overlap_pct) for matched items`

Word-level overlap between draft and live descriptions, after `clean_text()` normalisation:
- Strips punctuation per word: `"sauces."` → `"sauces"`
- Removes connector noise: `"and"` and `"&"` are both dropped before comparison so `"ham & cheese"` == `"ham and cheese"`

**`[AI]` tag handling:**
Items prefixed with `[ai]` in the draft description are AI-generated. The tag is stripped before the overlap calculation. Items are flagged:
- `is_ai_description = TRUE`
- `ai_desc_not_retained = TRUE` if word overlap < 60%

**Example — vendor `wu5t`:** All 14 matched items scored DA = **100%** after normalisation. The `"and"` vs `"&"` differences (e.g., `"beef and mushroom"` vs `"beef & mushroom"`) were previously causing false mismatches.

---

### Score 3 — Choice Accuracy (CA)

**Formula:** `live_option_count / draft_option_count × 100`

Compares choice group options the SCC generated (from `additional_item_info` JSON) against what appeared in the live product stream under `Choice_*` attributes.

**Example — vendor `wu5t` / [live menu](https://portal.foodpanda.com/pv2/ph/p/backoffice/vendors/wu5t/menus):**
> Draft "Wings" had 8 nested options: 3 sizes (Solo, Duo, Barkada Sharing) + 5 flavors (Buffalo, Cheese, Soy Garlic, Salted Egg, Teriyaki). 5 flavor options appeared in live under `Choice_Topping` → CA = 5/8 = **62.5%**. The 3 size options appeared as standalone primary items (no `Choice_*` attribute) — a known gap.

---

### Composite Score

`(TPC + DA + CA) / 3` — equal weight. Adjust denominators to rebalance.

**Cross-vendor weighted average** (for brand-level rollup):
```sql
SUM(tpc * total_live_items)      / SUM(total_live_items)       -- item-weighted TPC
SUM(da  * matched_items)         / SUM(matched_items)          -- item-weighted DA
SUM(ca  * draft_option_count)    / SUM(draft_option_count)     -- option-weighted CA
```

**April 2026 FP_PH results (473 clean vendors):**

| Metric | Drafts Not Retained (274) | Retained in SF (199) |
|---|---|---|
| TPC | 60.5% | 75.3% |
| DA | 54.6% | 60.8% |
| CA | 33.2% | 35.4% |
| **Composite** | **49.4%** | **57.2%** |

---

## Population & Exclusions

**Scope:** FP_PH · Non SSU · Seamless Market · April 2026 · Drafts Created (559 vendors)

**Shared menu exclusions (86 vendors):**
Vendors whose Menu Processing case comment references another vendor's menu are excluded. The script detects phrases in `Onboarding_Menu_Comments__c`:
- `"Sync from bcy5"` → vendor ID lookup
- `"Please mirror HZ3IDM"` → grid ID lookup
- `"Same as (t4i3)"` → vendor ID in parentheses
- `"Same with: HKFHEZ"` → grid in "same with" pattern
- `"SYNC TO THIS GRID - HREJHZ"` → explicit grid reference

**Example — grid `HTWSU9` / vendor `jvcw` / [live menu](https://portal.foodpanda.com/pv2/ph/p/backoffice/vendors/jvcw/menus):**
> Case 347727558 field `Onboarding_Menu_Comments__c` contains *"Please mirror bcy5 / Sync from bcy5"*. Source vendor `bcy5` (grid `HTHO8K`) resolves in the FP_PH vendors table → `is_confirmed_shared_menu = TRUE` → excluded from accuracy analysis.

All 86 confirmed shared menus were in the **Drafts Not Retained** bucket (0 in Retained). After exclusion: 274 not retained + 199 retained = **473 vendors for analysis**.

---

## Known Edge Cases & Fixes

### 1. Product stream time window — 11-second timing gap

**Example — vendor `a2de` / grid `HTW1VX` / [live menu](https://portal.foodpanda.com/pv2/ph/p/backoffice/vendors/a2de/menus):**
> Live items (squid balls, squid rolls, etc.) appeared in `product_stream` at `06:09:09` but the SCC catalog job completed at `06:09:20` — 11 seconds later. The original window start `scc.catalog_created_at` excluded these items. With no exact `squid balls` match in live, fuzzy matching incorrectly matched it to `squid rolls`.
>
> **Fix:** Window start changed to `mcc.menu_submitted_at` (menu file submission timestamp, always before the SCC job). `scc.catalog_created_at` kept as fallback only.

### 2. `_Choices` vs `Choice_*` attribute filter

The original filter `attr.name = '_Choices'` only caught the choice group **header** item. Individual options (e.g., Buffalo, Cheese under "Choice_Topping") carry an attribute named after their group, not `_Choices`.

**Example — vendor `wu5t`:** Items Buffalo, Cheese, Soy Garlic, Salted Egg, Teriyaki each carry `attribute_name = "Choice_Topping"` in `product_stream`. Original filter missed all of them.

**Fix:** `attr.name = '_Choices' OR STARTS_WITH(attr.name, 'Choice_')`

### 3. Draft options stored as nested JSON

The SCC stores choice options in `additional_item_info` as a JSON string, not as top-level items array entries. The `draft_options` CTE parses this:
```sql
UNNEST(JSON_QUERY_ARRAY(item.additional_item_info, '$.item_options'))  AS opt,
UNNEST(JSON_QUERY_ARRAY(opt, '$.option_selections'))                   AS sel
```

**Example — vendor `wu5t`:** "Wings" item had `additional_item_info` containing flavor options (buffalo, teriyaki, etc.) and size options (solo, duo, barkada sharing). These were invisible to the original `draft_menu_items` CTE which only unnested `items[]`.

### 4. No fuzzy name matching

Early versions used `EDIT_DISTANCE` for item matching. This caused:
- `"squid balls"` → matched to `"squid rolls"` (vendor `a2de` / grid `HTW1VX`)
- `"chicken nuggets"` → matched to `"chicken wings"` (same vendor)

These are clearly different products. **Fix:** Exact match only after `clean_text()` normalisation. `clean_text()` handles `&`/`and` and punctuation so genuine near-duplicates still match.

### 5. Shared menus referencing grid IDs instead of vendor IDs

**Example — grid `HTPH6D` / vendor `t07t`:**
> Comment: *"PLEASE ENSURE TO PROVIDE ALL NECESSARY OPTIONS SPECIALLY FLAVORS AND SYNC TO THIS GRID - HREJHZ"*. The reference is a grid ID (`HREJHZ`), not a vendor ID. Original regex extracted `"to"` (wrong token).
>
> **Fix:** Added `REGEXP_EXTRACT(LOWER(comment), r'sync to this grid\s*[-]\s*([a-z0-9]{4,6})')` as a fourth COALESCE pattern. Also added vendor-in-parentheses pattern for cases like `"BKSHP ONLY (t4i3)"`.

---

## File Structure

```
sql/
├── population/
│   └── MenuAccuracy_FP_PH_Apr2026_Population.sql   # 559 vendors + shared menu flag
├── accuracy_model/
│   ├── MenuAccuracy_FP_PH_Apr2026_Full_Extract.sql  # ← Main script (run this)
│   ├── MenuAccuracy_FP_PH_Apr2026_Scaled.sql        # Bucket summary only
│   ├── DescriptionVerification_vendor_wu5t.sql      # Single-vendor deep-dive template
│   └── DescriptionVerification_50pct_Match.sql      # Spot-check tool (50% overlap grids)
└── investigation/
    ├── MDSNotReceived-HungerStation-Change7-8-9-10.sql
    ├── MDSNotReceived-Talabat-Change3-4-5-6.sql
    └── MenuFileNotPresent-NB-Talabat-Change1-2.sql

MDS_MenuAccuracy_Project.md   # Full reference: pipeline, methods, edge cases
```

**To run the full analysis:** execute `sql/accuracy_model/MenuAccuracy_FP_PH_Apr2026_Full_Extract.sql` in BigQuery. Produces two result sets — vendor-level scores and item-level detail.

---

## Scaling to another country or period

In `MenuAccuracy_FP_PH_Apr2026_Full_Extract.sql`, change three lines:
```sql
f.global_entity_id = 'FP_PH'          -- → your target entity
f.onboard_month    = '2026-04-01'      -- → your target month (first of month)
ps.created_date >= DATE_SUB(CURRENT_DATE, INTERVAL 2 MONTH)  -- → cover your onboard month
```
