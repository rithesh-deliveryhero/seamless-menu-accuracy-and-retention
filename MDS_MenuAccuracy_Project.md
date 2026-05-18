# MDS Menu Accuracy — Project Reference

## Purpose

Measure how accurately the **SCC (Salesforce Content Creator)** auto-generated draft menu matches the vendor's actual live menu after onboarding. The goal is to produce three comparable scores per vendor that can be aggregated to a brand-level weighted average.

---

## Scope

- **Population:** Newly onboarded restaurant vendors (New Business, Win Back, Franchise Extension) in the last 12 months
- **Channels:** SSU (Self Sign-Up) + Non-SSU (sales-led)
- **Test vendor:** `wu5t` / `FP_PH` / grid `HTA5NP`

---

## Scripts

| File | Purpose |
|---|---|
| `DescriptionVerification_vendor_wu5t.sql` | Full scoring model for a single vendor — use this as the template |
| `DescriptionVerification_50pct_Match.sql` | Finds 5 grids with avg description overlap closest to 50% for manual spot-checking |
| `MDSNotReceived-HungerStation-Change7-8-9-10.sql` | Separate investigation — HungerStation Non-SSU MDS not received root cause |

---

## Pipeline Architecture

### Time Window

Every comparison is anchored to two timestamps per vendor:

| Anchor | Source | Meaning |
|---|---|---|
| **Start** | `scc_completion.catalog_created_at` (or `menu_case_closed.menu_submitted_at` if SCC job data missing) | When the system finished generating the draft |
| **End** | `sf_activation.sf_active_at` | When the vendor went live in Salesforce |

The **live menu snapshot** is taken from `product_stream` within this window — it captures the menu after the draft was generated but before the vendor was fully live (i.e. the version the vendor reviewed and accepted).

### CTE Chain (wu5t template)

```
onboarded_vendors_ssu / nssu → onboarded_vendors
                                         │
menu_case_closed ─────────────────────────┤
                                         │
sf_activation ────────────────────────────┤
                                         │
scc_completion ──────────────────────────┤
                                         │
draft_menu_items ────────────────────────┐│
draft_options (nested JSON) ─────────────┤│
live_menu (primary items) ───────────────┤├─→ matched_pairs → tmp_item_comparison
live_options (choice items) ─────────────┘│
                                          │
                               tmp_option_comparison
                                          │
                               RESULT 3: vendor scores
```

---

## Data Sources

| CTE | Table | What it gets |
|---|---|---|
| `draft_menu_items` | `dh_salesforce_scc_draft_menu.dh_salesforce_draft_menu` | Primary items from the SCC-generated draft |
| `draft_options` | Same table, `additional_item_info` JSON field | Nested choice options per primary item |
| `live_menu` | `curated_data_shared_data_stream.product_stream` | Primary items on the live platform |
| `live_options` | Same table, items with `STARTS_WITH(attr.name, 'Choice_')` | Choice group options on the live platform |
| `menu_case_closed` | `curated_data_shared_salesforce.case` | When the menu processing case was closed (start anchor) |
| `sf_activation` | `curated_data_shared_salesforce.account_history` | When SF account first went Active (end anchor) |
| `scc_completion` | `dh_salesforce_scc_draft_menu.dh_salesforce_scc_job_info` | When the SCC gms-products job completed |

---

## Scoring Model

### clean_text() Function

Applied to both draft and live descriptions before any word-overlap comparison:
- Lowercases and trims
- Strips all punctuation from each word (`REGEXP_REPLACE(w, r'[^a-z0-9]', '')`)
- Removes empty tokens and the word `"and"` (which maps to the same meaning as `"&"`, which becomes empty after stripping)

Effect: `"sauces."` == `"sauces"`, `"ham and cheese"` == `"ham & cheese"`

### Item Name Matching

Fuzzy match using EDIT_DISTANCE. For each draft item, the closest live item is selected via `QUALIFY ROW_NUMBER() ORDER BY EDIT_DISTANCE ASC`. Match is accepted if:

```
EDIT_DISTANCE(draft_name, live_name) / MAX(len_draft, len_live) ≤ 0.35
```

Exact matches (distance = 0) always win over fuzzy matches.

### Three Failure Modes

| `match_status` | Meaning |
|---|---|
| `matched_exact` | Item name identical in draft and live |
| `matched_fuzzy` | Item name close enough (edit distance ≤ 35%) |
| `draft_only` | Item was in draft but not in live — vendor removed it |
| `live_only_in_draft_as_option` | Item is in live as a standalone product but existed in the draft as a **nested choice option** (not a primary item) |
| `live_only` | Item is in live with no trace in the draft at all — vendor manually added it |

### Three Scores

#### 1. Total Product Completeness (TPC)
```
matched_items (exact + fuzzy) / total_live_items × 100
```
"What % of the live menu did the draft correctly anticipate?"

#### 2. Description Accuracy (DA)
```
AVG(desc_overlap_pct) for matched items where desc_overlap_pct IS NOT NULL
```
Word-level overlap after `clean_text()` normalisation, averaged across all matched items.

#### 3. Choice Accuracy (CA)
```
draft_options_present_in_live / total_draft_options × 100
```
"Of all choice options the system generated (e.g. Buffalo, Cheese, Solo, Duo), what % appeared in the live menu under a `Choice_*` attribute group?"

#### Composite Score
```
(TPC + DA + CA) / 3
```
Equal weights. Adjust the denominator and coefficients in Result 3 to rebalance.

#### Cross-Vendor Weighted Average (for brand-level rollup)
```sql
SUM(tpc * total_live_items) / SUM(total_live_items)
SUM(da  * matched_items)    / SUM(matched_items)
SUM(ca  * total_draft_options) / SUM(total_draft_options)
```

---

## Outliers & Edge Cases Discovered

### 1. `_Choices` vs `Choice_*` attribute naming

**Problem:** The original filter `attr.name = '_Choices'` only excluded the **group header** item from `live_menu`. Individual options within the group (e.g. Buffalo, Cheese) carry an attribute named after the group itself (e.g. `Choice_Topping`), not `_Choices`. These were leaking through as standalone primary items.

**Fix:** Extended the filter to:
```sql
AND NOT EXISTS (
  SELECT 1 FROM UNNEST(ps.content.attributes) AS attr
  WHERE attr.name = '_Choices' OR STARTS_WITH(attr.name, 'Choice_')
)
```

### 2. Draft options stored as nested JSON, not as primary items

**Problem:** The draft stores choice options inside `additional_item_info` as a JSON field:
```json
{"item_options": [{"option_name": "flavor options", "option_selections": [{"selection_name": "buffalo"}, ...]}]}
```
The original `draft_menu_items` CTE only unnested `items[]`, so options like Buffalo, Cheese were invisible to the comparison.

**Fix:** Added `draft_options` CTE that parses the JSON:
```sql
UNNEST(JSON_QUERY_ARRAY(item.additional_item_info, '$.item_options')) AS opt,
UNNEST(JSON_QUERY_ARRAY(opt, '$.option_selections')) AS sel
```

### 3. The Wings case (wu5t) — options split into standalone items by vendor

**What happened:** SCC generated "Wings" as a primary item with 8 nested options (3 sizes: Solo/Duo/Barkada Sharing + 5 flavours: Buffalo/Cheese/Salted Egg/Soy Garlic/Teriyaki). The vendor removed the Wings parent item and instead listed the options as **standalone primary products** in the live menu.

**Result in scores:**
- `wings` → `draft_only` (draft had it, live doesn't)
- `solo`, `duo`, `barkada sharing` → `live_only_in_draft_as_option` (draft_option_parent = wings)
- `buffalo`, `cheese`, etc. → filtered from `live_menu` by `Choice_` attribute; appear in `live_options` and count toward CA

### 4. Size options don't appear under `Choice_*` in the live platform

**Observation:** Flavor options (Buffalo, Cheese etc.) carry a `Choice_Topping` attribute in product_stream. Size options (Solo, Duo, Barkada Sharing) appear as **standalone items** with no `Choice_*` attribute, so they:
- Pass the `live_menu` filter (not excluded by `Choice_` rule)
- Do NOT appear in `live_options`
- Show as `live_only_in_draft_as_option` in the item comparison
- Do NOT contribute to CA (Choice Accuracy) — they're missed

**Impact on wu5t CA:** 5/8 = 62.5% (the 3 size options are uncounted). This is a known limitation.

### 5. Description punctuation & connector words

**Original problem:** `"sauces."` (draft) vs `"sauces"` (live) scored as non-matching. `"ham and cheese"` vs `"ham & cheese"` also failed.

**Fix:** `clean_text()` function strips terminal punctuation from every word and drops `"and"` before the word-overlap calculation. `"&"` becomes `""` after `REGEXP_REPLACE(w, r'[^a-z0-9]', '')` and is then filtered as an empty token.

### 6. `IS` is a reserved keyword in BigQuery

Cannot be used as a table alias. Use `itmsi` or similar.

### 7. Bare `NULL` typed as `INT64` in UNION ALL

In BigQuery, `NULL` without a cast defaults to `INT64`. In UNION ALL blocks, always use:
```sql
CAST(NULL AS STRING)
CAST(NULL AS FLOAT64)
```

### 8. `DECLARE` must precede `CREATE TEMP FUNCTION` in BigQuery scripts

Order required:
```sql
DECLARE name STRING DEFAULT 'value';
CREATE TEMP FUNCTION ...;
CREATE TEMP TABLE ...;
SELECT ...;
```

---

## wu5t Test Results (validated 2026-05-18)

| Metric | Value | Detail |
|---|---|---|
| Total draft items | 15 | |
| Total live items | 21 | |
| Matched items | 14 | 13 exact + 1 fuzzy |
| **Total Product Completeness** | **66.7%** | 14/21 live items anticipated |
| **Description Accuracy** | **100.0%** | All matched items had identical descriptions after normalisation |
| Total draft options | 8 | 3 sizes + 5 flavours under Wings |
| Live options matched | 5 | The 5 flavours (have Choice_Topping attr); 3 sizes not in live_options |
| **Choice Accuracy** | **62.5%** | 5/8 draft options in live |
| **Composite Score** | **76.4%** | Equal 1/3 weight |

---

## Next Steps

- [ ] Scale to full FP_PH population (replace hardcoded `vendor_id = "wu5t"` and `grid__c = "HTA5NP"` with the full `onboarded_vendors` CTE chain)
- [ ] Decide whether size options not appearing under `Choice_*` should be excluded from CA denominator or handled separately
- [ ] Agree on composite score weights (currently 1/3 each)
- [ ] Apply to other countries by changing `ov.global_entity_id = "FP_PH"` and `product_stream` date range
