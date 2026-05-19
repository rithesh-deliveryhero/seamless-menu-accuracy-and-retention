-- ================================================================
-- MENU ACCURACY MODEL v3
-- FP_PH | Non SSU | Seamless Market | April 2026 | 473 clean vendors
--
-- Three independent metrics:
--   TPC  — Total Product Completeness
--          Bidirectional word-overlap name matching (≥60% both directions)
--          Primary items only — no choice groups / options anywhere
--
--   DA   — Description Accuracy (NON-AI descriptions only)
--          [ai]-tagged items excluded from both numerator and denominator
--
--   ADAR — AI Description Adoption Rate (new)
--          % of AI-tagged descriptions retained in live (≥60% word overlap)
--
-- No composite score — metrics are independent.
-- ================================================================

CREATE TEMP FUNCTION clean_text(s STRING) RETURNS STRING AS (
  -- Normalises for comparison: lowercase, strip punctuation per word, drop "and"
  ARRAY_TO_STRING(
    ARRAY(
      SELECT REGEXP_REPLACE(w, r'[^a-z0-9]', '')
      FROM UNNEST(SPLIT(LOWER(TRIM(COALESCE(s, ''))), ' ')) AS w
      WHERE REGEXP_REPLACE(w, r'[^a-z0-9]', '') NOT IN ('', 'and')
    ), ' '
  )
);

CREATE TEMP FUNCTION clean_desc(s STRING) RETURNS STRING AS (
  -- Same as clean_text but also strips [ai] prefix from draft descriptions
  clean_text(REGEXP_REPLACE(COALESCE(s, ''), r'(?i)\[ai\]\s*', ''))
);

-- ================================================================
-- Shared menu flag (unchanged from v2)
-- ================================================================
CREATE TEMP TABLE tmp_shared_menu AS (
WITH menu_cases AS (
  SELECT c.grid__c, c.global_entity_id,
    COALESCE(
      REGEXP_EXTRACT(LOWER(c.onboarding_menu_comments__c), r'(?:sync from|mirror|copy menu of:?\s*|same menu with(?:\s+vendor code)?\s*|same as|sync)\s*\[?([a-z][a-z0-9-]{1,9})'),
      REGEXP_EXTRACT(LOWER(c.onboarding_menu_comments__c), r'same with[:\s]+([a-z0-9]{4,6})'),
      REGEXP_EXTRACT(LOWER(c.onboarding_menu_comments__c), r'\(([a-z][a-z0-9]{2,5})\)'),
      REGEXP_EXTRACT(LOWER(c.onboarding_menu_comments__c), r'sync to this grid\s*[-]\s*([a-z0-9]{4,6})')
    ) AS source_vendor_raw
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.case` AS c
  WHERE c.global_entity_id = 'FP_PH' AND c.type = 'Menu Processing'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY c.grid__c, c.global_entity_id ORDER BY c.createddate DESC) = 1
)
SELECT mc.grid__c, mc.global_entity_id,
  mc.source_vendor_raw IS NOT NULL
    AND COALESCE(src_by_vid.vendor_id, src_by_grid.vendor_id) IS NOT NULL AS is_shared_menu
FROM menu_cases AS mc
LEFT JOIN `fulfillment-dwh-production.curated_data_shared_coredata_business.vendors` AS src_by_vid
  ON src_by_vid.vendor_id = REGEXP_REPLACE(mc.source_vendor_raw, r'^[a-z]{2,4}-', '') AND src_by_vid.global_entity_id = 'FP_PH'
LEFT JOIN `fulfillment-dwh-production.curated_data_shared_coredata_business.vendors` AS src_by_grid
  ON src_by_grid.salesforce.grid = UPPER(REGEXP_REPLACE(mc.source_vendor_raw, r'^[a-z]{2,4}-', '')) AND src_by_grid.global_entity_id = 'FP_PH'
);

-- ================================================================
-- PART 1 — Item-level comparison (primary items only, no options)
-- ================================================================
CREATE TEMP TABLE tmp_item_comparison AS (
WITH

population AS (
  SELECT
    f.global_entity_id, f.grid_id, f.vendor_id,
    CASE
      WHEN f.is_funnel_drafts_not_retained = TRUE THEN 'Drafts Not Retained'
      WHEN f.is_funnel_retained_in_sf      = TRUE THEN 'Retained in SF'
    END AS draft_outcome
  FROM `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel` AS f
  LEFT JOIN tmp_shared_menu AS sm ON f.grid_id = sm.grid__c AND f.global_entity_id = sm.global_entity_id
  WHERE f.global_entity_id       = 'FP_PH'
    AND f.onboard_month          = '2026-04-01'
    AND f.account_source_curated = 'Non SSU'
    AND f.is_seamless_market     = TRUE
    AND (f.is_funnel_drafts_not_retained = TRUE OR f.is_funnel_retained_in_sf = TRUE)
    AND COALESCE(sm.is_shared_menu, FALSE) = FALSE
),

menu_case_closed AS (
  SELECT c.global_entity_id, c.grid__c AS grid,
    ARRAY_REVERSE(SPLIT(REGEXP_REPLACE(TRIM(c.backend_id__c), r"[^a-zA-Z0-9\s]+", "-"), "-"))[SAFE_OFFSET(0)] AS vendor_id,
    MIN(c.closeddate) AS menu_submitted_at
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.case` AS c
  WHERE c.type = 'Menu Processing' AND c.status = 'Closed'
    AND c.global_entity_id = 'FP_PH'
    AND DATE(c.closeddate) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH), MONTH)
    AND c.grid__c IN (SELECT grid_id FROM population)
  GROUP BY 1, 2, 3
),

sf_activation AS (
  SELECT a.global_entity_id, a.grid__c AS grid, MIN(ah.createddate) AS sf_active_at
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.account_history` AS ah
    JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.account` AS a
      ON ah.accountid = a.id AND ah.global_entity_id = a.global_entity_id
  WHERE ah.field = 'Account_Status__c' AND ah.newvalue = 'Active'
    AND a.global_entity_id = 'FP_PH'
    AND a.grid__c IN (SELECT grid_id FROM population)
    AND DATE(ah.createddate) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE, INTERVAL 13 MONTH), MONTH)
  GROUP BY 1, 2
),

scc_completion AS (
  SELECT job.vendor_id, job.global_entity_id, MIN(job.timestamp) AS catalog_created_at
  FROM `dh-central-salesforce-tech.dh_salesforce_scc_draft_menu.dh_salesforce_scc_job_info` AS job
    JOIN menu_case_closed AS mcc ON job.vendor_id = mcc.vendor_id AND job.global_entity_id = mcc.global_entity_id
  WHERE job.status = 'Completed' AND job.type = 'gms-products'
    AND TIMESTAMP_DIFF(job.timestamp, mcc.menu_submitted_at, HOUR) BETWEEN -168 AND 744
  GROUP BY 1, 2
),

-- Primary draft items only — no options/choice groups
draft_menu_items AS (
  SELECT DISTINCT dm.vendor_id, dm.global_entity_id,
    LOWER(TRIM(item.name))        AS item_name,
    LOWER(TRIM(item.description)) AS item_description,
    REGEXP_CONTAINS(LOWER(TRIM(COALESCE(item.description, ''))), r'\[ai\]') AS is_ai_description
  FROM `dh-central-salesforce-tech.dh_salesforce_scc_draft_menu.dh_salesforce_draft_menu` AS dm
    , UNNEST(dm.items) AS item
  WHERE dm.vendor_id IN (SELECT vendor_id FROM population)
    AND dm.global_entity_id = 'FP_PH'
    AND CHAR_LENGTH(item.name) > 0
),

-- Primary live items only — Choice_* already excluded by attribute filter
live_menu AS (
  SELECT DISTINCT
    ps.content.vendor.vendor_id        AS vendor_id,
    ps.global_entity_id,
    LOWER(TRIM(ps.content.name))        AS item_name,
    LOWER(TRIM(ps.content.description)) AS live_desc
  FROM population AS ov
    JOIN sf_activation AS sfa ON ov.grid_id = sfa.grid AND ov.global_entity_id = sfa.global_entity_id
    LEFT JOIN menu_case_closed AS mcc ON ov.grid_id = mcc.grid AND ov.global_entity_id = mcc.global_entity_id
    LEFT JOIN scc_completion AS scc ON ov.vendor_id = scc.vendor_id AND ov.global_entity_id = scc.global_entity_id
    JOIN `fulfillment-dwh-production.curated_data_shared_data_stream.product_stream` AS ps
      ON ps.global_entity_id         = ov.global_entity_id
     AND ps.content.vendor.vendor_id = ov.vendor_id
     AND ps.timestamp BETWEEN
           COALESCE(TIMESTAMP(mcc.menu_submitted_at), TIMESTAMP(scc.catalog_created_at))
           AND TIMESTAMP(sfa.sf_active_at)
     AND ps.created_date >= DATE_SUB(CURRENT_DATE, INTERVAL 2 MONTH)
  WHERE NOT COALESCE(ps.content.deleted, FALSE)
    AND NOT EXISTS (
      SELECT 1 FROM UNNEST(ps.content.attributes) AS attr
      WHERE attr.name = '_Choices' OR STARTS_WITH(attr.name, 'Choice_')
    )
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ps.content.vendor.vendor_id, ps.global_entity_id, LOWER(TRIM(ps.content.name))
    ORDER BY ps.content.timestamp
  ) = 1
),

-- ----------------------------------------------------------------
-- Bidirectional word-overlap name matching
-- Both directions must be ≥ 60% for a fuzzy match to fire.
-- This prevents single-word traps and wrong-protein matches.
--
-- draft_coverage = shared_words / draft_word_count ≥ 0.60
-- live_coverage  = shared_words / live_word_count  ≥ 0.60
--
-- QUALIFY: exact match wins; ties broken by highest avg coverage.
-- ----------------------------------------------------------------
matched_pairs AS (
  SELECT DISTINCT
    di.vendor_id,
    di.global_entity_id,
    di.item_name        AS draft_item_name,
    li.item_name        AS live_item_name,
    di.item_description AS draft_description,
    li.live_desc        AS live_description,
    di.is_ai_description,
    CASE
      WHEN li.item_name IS NULL                                THEN 'draft_only'
      WHEN clean_text(di.item_name) = clean_text(li.item_name) THEN 'matched_exact'
      ELSE                                                      'matched_fuzzy'
    END AS match_status,

    -- Description overlap: [ai] stripped from draft side; used for both DA and ADAR
    ROUND(
      SAFE_DIVIDE(
        (SELECT COUNT(1) FROM UNNEST(SPLIT(clean_desc(di.item_description), ' ')) AS w1
         WHERE w1 != '' AND w1 IN UNNEST(SPLIT(clean_text(li.live_desc), ' '))),
        (SELECT COUNT(1) FROM UNNEST(SPLIT(clean_desc(di.item_description), ' ')) AS w2
         WHERE w2 != '')
      ) * 100, 1
    ) AS desc_overlap_pct

  FROM draft_menu_items AS di
  LEFT JOIN live_menu AS li
    ON di.vendor_id        = li.vendor_id
   AND di.global_entity_id = li.global_entity_id
   AND (
       -- Exact match (preferred)
       clean_text(di.item_name) = clean_text(li.item_name)
       -- Fuzzy: bidirectional word overlap ≥ 60%
     OR (
         SAFE_DIVIDE(
           (SELECT COUNT(1) FROM UNNEST(SPLIT(clean_text(di.item_name), ' ')) AS wd
            WHERE wd != '' AND wd IN UNNEST(SPLIT(clean_text(li.item_name), ' '))),
           NULLIF((SELECT COUNT(1) FROM UNNEST(SPLIT(clean_text(di.item_name), ' ')) AS wd WHERE wd != ''), 0)
         ) >= 0.6
         AND
         SAFE_DIVIDE(
           (SELECT COUNT(1) FROM UNNEST(SPLIT(clean_text(li.item_name), ' ')) AS wl
            WHERE wl != '' AND wl IN UNNEST(SPLIT(clean_text(di.item_name), ' '))),
           NULLIF((SELECT COUNT(1) FROM UNNEST(SPLIT(clean_text(li.item_name), ' ')) AS wl WHERE wl != ''), 0)
         ) >= 0.6
       )
   )
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY di.vendor_id, di.global_entity_id, di.item_name
    ORDER BY
      -- Exact match always first
      IF(clean_text(di.item_name) = clean_text(li.item_name), 0, 1) ASC,
      -- Then highest average bidirectional coverage
      (
        SAFE_DIVIDE(
          (SELECT COUNT(1) FROM UNNEST(SPLIT(clean_text(di.item_name), ' ')) AS wd
           WHERE wd != '' AND wd IN UNNEST(SPLIT(clean_text(li.item_name), ' '))),
          NULLIF((SELECT COUNT(1) FROM UNNEST(SPLIT(clean_text(di.item_name), ' ')) AS wd WHERE wd != ''), 0)
        )
        +
        SAFE_DIVIDE(
          (SELECT COUNT(1) FROM UNNEST(SPLIT(clean_text(li.item_name), ' ')) AS wl
           WHERE wl != '' AND wl IN UNNEST(SPLIT(clean_text(di.item_name), ' '))),
          NULLIF((SELECT COUNT(1) FROM UNNEST(SPLIT(clean_text(li.item_name), ' ')) AS wl WHERE wl != ''), 0)
        )
      ) / 2.0 DESC
  ) = 1
)

-- Draft items (matched exact, matched fuzzy, draft_only)
SELECT
  pop.draft_outcome,
  mp.vendor_id, mp.global_entity_id,
  mp.match_status,
  mp.draft_item_name,
  mp.live_item_name,
  mp.draft_description,
  mp.live_description,
  mp.is_ai_description,
  mp.desc_overlap_pct
FROM matched_pairs AS mp
JOIN population AS pop ON mp.vendor_id = pop.vendor_id AND mp.global_entity_id = pop.global_entity_id

UNION ALL

-- Live-only items: in live but matched by neither exact nor fuzzy
SELECT
  pop.draft_outcome,
  li.vendor_id, li.global_entity_id,
  'live_only' AS match_status,
  CAST(NULL AS STRING) AS draft_item_name,
  li.item_name         AS live_item_name,
  CAST(NULL AS STRING) AS draft_description,
  li.live_desc         AS live_description,
  FALSE                AS is_ai_description,
  CAST(NULL AS FLOAT64) AS desc_overlap_pct
FROM live_menu AS li
  JOIN population AS pop ON li.vendor_id = pop.vendor_id AND li.global_entity_id = pop.global_entity_id
  LEFT JOIN matched_pairs AS mp
    ON li.vendor_id = mp.vendor_id AND li.global_entity_id = mp.global_entity_id
   AND li.item_name = mp.live_item_name
WHERE mp.live_item_name IS NULL
);


-- ================================================================
-- RESULT 1: Vendor-level scores — one row per vendor
--
-- TPC  = (exact_matches + fuzzy_matches) / total_live_items
-- DA   = avg desc word overlap for non-AI matched items only
--        (items with [ai] tag excluded from numerator AND denominator)
-- ADAR = % of AI-tagged matched items where desc_overlap ≥ 60%
-- ================================================================
WITH vendor_scores AS (
  SELECT
    draft_outcome,
    vendor_id,
    global_entity_id,

    -- Item counts
    COUNT(DISTINCT live_item_name)                                                    AS total_live_items,
    COUNT(DISTINCT draft_item_name)                                                   AS total_draft_items,
    COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy'))                       AS matched_items,
    COUNTIF(match_status = 'matched_exact')                                           AS exact_matches,
    COUNTIF(match_status = 'matched_fuzzy')                                           AS fuzzy_matches,
    COUNTIF(match_status = 'draft_only')                                              AS draft_only_items,
    COUNTIF(match_status = 'live_only')                                               AS live_only_items,

    -- TPC: live_only items inflate denominator → reduce score (intentional)
    ROUND(100.0 * COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy'))
                / NULLIF(COUNT(DISTINCT live_item_name), 0), 1)                       AS total_product_completeness_pct,

    -- DA: non-AI descriptions only
    -- Excludes items where draft has [ai] tag from both numerator and denominator
    -- Excludes items with no description on either side
    ROUND(AVG(
      IF(match_status IN ('matched_exact', 'matched_fuzzy')
         AND NOT is_ai_description
         AND desc_overlap_pct IS NOT NULL,
         desc_overlap_pct, NULL)
    ), 1)                                                                             AS description_accuracy_pct,

    COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy')
            AND NOT is_ai_description AND desc_overlap_pct IS NOT NULL)               AS da_items_evaluated,

    -- ADAR: AI descriptions — were they kept?
    COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy') AND is_ai_description) AS ai_desc_item_count,
    COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy')
            AND is_ai_description AND COALESCE(desc_overlap_pct, 0) >= 60)            AS ai_desc_adopted_count,
    ROUND(100.0
      * COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy')
                AND is_ai_description AND COALESCE(desc_overlap_pct, 0) >= 60)
      / NULLIF(COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy')
                       AND is_ai_description), 0), 1)                                 AS ai_desc_adoption_pct,
    COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy') AND is_ai_description) > 0
                                                                                      AS has_ai_descriptions

  FROM tmp_item_comparison
  GROUP BY 1, 2, 3
)
SELECT *
FROM vendor_scores
ORDER BY draft_outcome, total_product_completeness_pct;


-- ================================================================
-- RESULT 2: Bucket-level weighted summary
-- Weights: TPC by live items, DA by da_items_evaluated, ADAR by ai_desc_item_count
-- ================================================================
WITH vendor_scores AS (
  SELECT
    draft_outcome,
    vendor_id,
    COUNT(DISTINCT live_item_name)                                                    AS total_live_items,
    COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy'))                       AS matched_items,
    ROUND(100.0 * COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy'))
                / NULLIF(COUNT(DISTINCT live_item_name), 0), 1)                       AS tpc,
    COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy')
            AND NOT is_ai_description AND desc_overlap_pct IS NOT NULL)               AS da_items,
    ROUND(AVG(IF(match_status IN ('matched_exact', 'matched_fuzzy')
                 AND NOT is_ai_description AND desc_overlap_pct IS NOT NULL,
                 desc_overlap_pct, NULL)), 1)                                         AS da,
    COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy') AND is_ai_description) AS ai_items,
    ROUND(100.0
      * COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy')
                AND is_ai_description AND COALESCE(desc_overlap_pct, 0) >= 60)
      / NULLIF(COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy')
                       AND is_ai_description), 0), 1)                                 AS adar
  FROM tmp_item_comparison
  GROUP BY 1, 2
)
SELECT
  draft_outcome,
  COUNT(DISTINCT vendor_id)                                                           AS vendors,
  SUM(total_live_items)                                                               AS total_live_items,
  SUM(matched_items)                                                                  AS total_matched,
  SUM(da_items)                                                                       AS da_items_evaluated,
  SUM(ai_items)                                                                       AS ai_desc_items,

  -- Item-count weighted averages
  ROUND(SUM(tpc * total_live_items) / NULLIF(SUM(total_live_items), 0), 1)           AS tpc_weighted_avg,
  ROUND(SUM(da  * da_items)         / NULLIF(SUM(da_items), 0), 1)                   AS da_weighted_avg,
  ROUND(SUM(adar * ai_items)        / NULLIF(SUM(ai_items), 0), 1)                   AS adar_weighted_avg

FROM vendor_scores
GROUP BY draft_outcome
ORDER BY draft_outcome;


-- ================================================================
-- RESULT 3: Item-level detail
-- Includes: matched (exact/fuzzy), draft_only, live_only
-- Use to drill into specific vendors or match_status buckets
-- ================================================================
SELECT
  draft_outcome,
  vendor_id,
  global_entity_id,
  match_status,
  draft_item_name,
  live_item_name,
  draft_description,
  live_description,
  is_ai_description,
  desc_overlap_pct,
  -- DA flag: non-AI item with description rewritten (< 60% overlap)
  (NOT is_ai_description AND match_status IN ('matched_exact', 'matched_fuzzy')
   AND COALESCE(desc_overlap_pct, 0) < 60)                                            AS non_ai_desc_rewritten,
  -- ADAR flag: AI item where description was adopted
  (is_ai_description AND match_status IN ('matched_exact', 'matched_fuzzy')
   AND COALESCE(desc_overlap_pct, 0) >= 60)                                           AS ai_desc_adopted
FROM tmp_item_comparison
ORDER BY
  draft_outcome,
  vendor_id,
  CASE match_status
    WHEN 'matched_exact' THEN 1
    WHEN 'matched_fuzzy' THEN 2
    WHEN 'draft_only'    THEN 3
    WHEN 'live_only'     THEN 4
  END,
  COALESCE(draft_item_name, live_item_name);
