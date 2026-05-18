-- ================================================================
-- MENU ACCURACY — Full Extract  v2
-- FP_PH | Non SSU | Seamless Market | April 2026 | 473 clean vendors
--
-- Fixes vs v1:
--   - Exact match only (no fuzzy EDIT_DISTANCE — caused squid balls → squid roll)
--   - Window start: mcc.menu_submitted_at (not scc.catalog_created_at)
--     → fixes 11-second gap where live items were excluded
--   - Options = match: live_only_in_draft_as_option counts toward TPC;
--     draft primary items found in live choice groups → draft_item_as_live_option
--   - AI descriptions: [ai] tag stripped before overlap; flags per item + vendor metric
--
-- RESULT 1: One row per vendor  — TPC, DA, CA, AI retention, Composite
-- RESULT 2: One row per item    — full item-level detail for all vendors
-- ================================================================

CREATE TEMP FUNCTION clean_text(s STRING) RETURNS STRING AS (
  ARRAY_TO_STRING(
    ARRAY(
      SELECT REGEXP_REPLACE(w, r'[^a-z0-9]', '')
      FROM UNNEST(SPLIT(LOWER(TRIM(COALESCE(s, ''))), ' ')) AS w
      WHERE REGEXP_REPLACE(w, r'[^a-z0-9]', '') NOT IN ('', 'and')
    ), ' '
  )
);

-- Strip [ai] tag then clean; used for description overlap calculation
CREATE TEMP FUNCTION clean_desc(s STRING) RETURNS STRING AS (
  clean_text(REGEXP_REPLACE(COALESCE(s, ''), r'(?i)\[ai\]\s*', ''))
);

-- ================================================================
-- Shared menu flag
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
  ON src_by_vid.vendor_id        = REGEXP_REPLACE(mc.source_vendor_raw, r'^[a-z]{2,4}-', '')
 AND src_by_vid.global_entity_id = 'FP_PH'
LEFT JOIN `fulfillment-dwh-production.curated_data_shared_coredata_business.vendors` AS src_by_grid
  ON src_by_grid.salesforce.grid  = UPPER(REGEXP_REPLACE(mc.source_vendor_raw, r'^[a-z]{2,4}-', ''))
 AND src_by_grid.global_entity_id = 'FP_PH'
);

-- ================================================================
-- Item-level comparison
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

draft_options AS (
  SELECT DISTINCT dm.vendor_id, dm.global_entity_id,
    LOWER(TRIM(item.name))                           AS parent_item_name,
    LOWER(TRIM(JSON_VALUE(opt, '$.option_name')))    AS option_group,
    LOWER(TRIM(JSON_VALUE(sel, '$.selection_name'))) AS option_name
  FROM `dh-central-salesforce-tech.dh_salesforce_scc_draft_menu.dh_salesforce_draft_menu` AS dm
    , UNNEST(dm.items) AS item
    , UNNEST(JSON_QUERY_ARRAY(item.additional_item_info, '$.item_options'))  AS opt
    , UNNEST(JSON_QUERY_ARRAY(opt, '$.option_selections'))                   AS sel
  WHERE dm.vendor_id IN (SELECT vendor_id FROM population)
    AND dm.global_entity_id = 'FP_PH'
    AND CHAR_LENGTH(item.name) > 0
    AND JSON_VALUE(sel, '$.selection_name') IS NOT NULL
),

live_menu AS (
  SELECT DISTINCT
    ps.content.vendor.vendor_id        AS vendor_id,
    ps.global_entity_id,
    LOWER(TRIM(ps.content.name))        AS item_name,
    LOWER(TRIM(ps.content.description)) AS live_desc
  FROM population AS ov
    JOIN sf_activation AS sfa ON ov.grid_id = sfa.grid AND ov.global_entity_id = sfa.global_entity_id
    -- FIX: use menu_submitted_at as window start (captures items created just before SCC job completes)
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

-- Items in live product stream that belong to a choice group
live_options AS (
  SELECT DISTINCT
    ps.content.vendor.vendor_id  AS vendor_id,
    ps.global_entity_id,
    LOWER(TRIM(ps.content.name)) AS option_name
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
    , UNNEST(ps.content.attributes) AS attr
  WHERE NOT COALESCE(ps.content.deleted, FALSE)
    AND STARTS_WITH(attr.name, 'Choice_')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ps.content.vendor.vendor_id, ps.global_entity_id, LOWER(TRIM(ps.content.name)), attr.name
    ORDER BY ps.content.timestamp
  ) = 1
),

-- Exact name match (after clean_text normalisation) — no fuzzy matching
matched_pairs AS (
  SELECT DISTINCT
    di.vendor_id, di.global_entity_id,
    di.item_name        AS draft_item_name,
    li.item_name        AS live_item_name,
    di.item_description AS draft_description,
    li.live_desc        AS live_description,
    di.is_ai_description,
    CASE
      WHEN li.item_name IS NULL THEN 'draft_only'
      ELSE                       'matched'
    END AS match_status,
    -- Description overlap: [ai] tag stripped from draft before comparison
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
   -- Exact match after normalisation: handles "and"/"&", punctuation
   AND clean_text(di.item_name) = clean_text(li.item_name)
)

-- Mode 1: exact item name match draft ↔ live primary
SELECT
  pop.draft_outcome,
  mp.vendor_id, mp.global_entity_id,
  'matched'             AS match_status,
  CAST(NULL AS STRING)  AS draft_option_parent,
  mp.draft_item_name, mp.live_item_name,
  mp.draft_description, mp.live_description,
  mp.is_ai_description,
  mp.desc_overlap_pct,
  mp.is_ai_description AND COALESCE(mp.desc_overlap_pct, 0) < 60 AS ai_desc_not_retained
FROM matched_pairs AS mp
JOIN population AS pop ON mp.vendor_id = pop.vendor_id AND mp.global_entity_id = pop.global_entity_id
WHERE mp.match_status = 'matched'

UNION ALL

-- Mode 2: draft item not in live primary — check if it appeared in live as a choice option
SELECT
  pop.draft_outcome,
  mp.vendor_id, mp.global_entity_id,
  CASE WHEN lo.option_name IS NOT NULL THEN 'draft_item_as_live_option' ELSE 'draft_only' END AS match_status,
  CAST(NULL AS STRING)  AS draft_option_parent,
  mp.draft_item_name, CAST(NULL AS STRING) AS live_item_name,
  mp.draft_description, CAST(NULL AS STRING) AS live_description,
  mp.is_ai_description,
  CAST(NULL AS FLOAT64) AS desc_overlap_pct,
  -- AI descriptions for draft_only items are not retained
  mp.is_ai_description AND TRUE AS ai_desc_not_retained
FROM matched_pairs AS mp
JOIN population AS pop ON mp.vendor_id = pop.vendor_id AND mp.global_entity_id = pop.global_entity_id
LEFT JOIN live_options AS lo
  ON mp.vendor_id = lo.vendor_id AND mp.global_entity_id = lo.global_entity_id
 AND clean_text(mp.draft_item_name) = clean_text(lo.option_name)
WHERE mp.match_status = 'draft_only'

UNION ALL

-- Mode 3: live primary item not in draft — check if it was a draft option (counts toward TPC)
SELECT
  pop.draft_outcome,
  li.vendor_id, li.global_entity_id,
  CASE WHEN dopt.option_name IS NOT NULL THEN 'live_only_in_draft_as_option' ELSE 'live_only' END AS match_status,
  dopt.parent_item_name AS draft_option_parent,
  CAST(NULL AS STRING)  AS draft_item_name,
  li.item_name          AS live_item_name,
  CAST(NULL AS STRING)  AS draft_description,
  li.live_desc          AS live_description,
  FALSE                 AS is_ai_description,
  CAST(NULL AS FLOAT64) AS desc_overlap_pct,
  FALSE                 AS ai_desc_not_retained
FROM live_menu AS li
  JOIN population AS pop ON li.vendor_id = pop.vendor_id AND li.global_entity_id = pop.global_entity_id
  LEFT JOIN matched_pairs AS mp
    ON li.vendor_id = mp.vendor_id AND li.global_entity_id = mp.global_entity_id
   AND clean_text(li.item_name) = clean_text(mp.live_item_name)
  LEFT JOIN draft_options AS dopt
    ON li.vendor_id = dopt.vendor_id AND li.global_entity_id = dopt.global_entity_id
   AND clean_text(li.item_name) = clean_text(dopt.option_name)
WHERE mp.live_item_name IS NULL
);

-- ================================================================
-- Option comparison
-- ================================================================
CREATE TEMP TABLE tmp_option_comparison AS (
WITH

population AS (
  SELECT f.global_entity_id, f.grid_id, f.vendor_id
  FROM `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel` AS f
  LEFT JOIN tmp_shared_menu AS sm ON f.grid_id = sm.grid__c AND f.global_entity_id = sm.global_entity_id
  WHERE f.global_entity_id = 'FP_PH' AND f.onboard_month = '2026-04-01'
    AND f.account_source_curated = 'Non SSU' AND f.is_seamless_market = TRUE
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

draft_options AS (
  SELECT DISTINCT dm.vendor_id, dm.global_entity_id,
    LOWER(TRIM(item.name))                           AS parent_item_name,
    LOWER(TRIM(JSON_VALUE(opt, '$.option_name')))    AS option_group,
    LOWER(TRIM(JSON_VALUE(sel, '$.selection_name'))) AS option_name
  FROM `dh-central-salesforce-tech.dh_salesforce_scc_draft_menu.dh_salesforce_draft_menu` AS dm
    , UNNEST(dm.items) AS item
    , UNNEST(JSON_QUERY_ARRAY(item.additional_item_info, '$.item_options'))  AS opt
    , UNNEST(JSON_QUERY_ARRAY(opt, '$.option_selections'))                   AS sel
  WHERE dm.vendor_id IN (SELECT vendor_id FROM population)
    AND dm.global_entity_id = 'FP_PH'
    AND CHAR_LENGTH(item.name) > 0
    AND JSON_VALUE(sel, '$.selection_name') IS NOT NULL
),

live_options AS (
  SELECT DISTINCT ps.content.vendor.vendor_id AS vendor_id, ps.global_entity_id,
    LOWER(TRIM(ps.content.name)) AS option_name
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
    , UNNEST(ps.content.attributes) AS attr
  WHERE NOT COALESCE(ps.content.deleted, FALSE) AND STARTS_WITH(attr.name, 'Choice_')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ps.content.vendor.vendor_id, ps.global_entity_id, LOWER(TRIM(ps.content.name)), attr.name
    ORDER BY ps.content.timestamp
  ) = 1
)

SELECT
  dopt.vendor_id, dopt.global_entity_id,
  COUNT(DISTINCT dopt.option_name) AS draft_option_count,
  COUNT(DISTINCT lo.option_name)   AS live_option_count
FROM draft_options AS dopt
  LEFT JOIN live_options AS lo
    ON dopt.vendor_id        = lo.vendor_id
   AND dopt.global_entity_id = lo.global_entity_id
   AND clean_text(dopt.option_name) = clean_text(lo.option_name)
GROUP BY 1, 2
);


-- ================================================================
-- RESULT 1: Vendor-level aggregate — one row per menu
--
-- TPC = anticipated_items / total_live_items
--   Numerator  (anticipated): matched + live_only_in_draft_as_option
--     • matched                    — draft primary found in live primary
--     • live_only_in_draft_as_option — live primary item was a draft option; draft knew about it
--   Denominator (total_live_items): ALL live primary items, including live_only
--     • live_only items inflate the denominator → reduce TPC   ← intentional
--   Excluded from formula (informational only):
--     • draft_only               — draft over-generated; no penalty, no credit
--     • draft_item_as_live_option — draft primary became a live choice option; SUCCESS
-- ================================================================
WITH
item_scores AS (
  SELECT
    vendor_id, global_entity_id, draft_outcome,

    -- Denominator: ALL live primary items (live_only included → reduces TPC)
    COUNT(DISTINCT live_item_name)                                               AS total_live_items,
    COUNT(DISTINCT draft_item_name)                                              AS total_draft_items,

    -- Numerator: items the draft correctly anticipated
    COUNTIF(match_status IN ('matched', 'live_only_in_draft_as_option'))         AS anticipated_items,
    COUNTIF(match_status = 'matched')                                            AS exact_matched_items,
    COUNTIF(match_status = 'live_only_in_draft_as_option')                       AS live_items_as_draft_options,
    -- Success: draft primary found in live as choice option (not a failure)
    COUNTIF(match_status = 'draft_item_as_live_option')                          AS draft_items_in_live_options,
    -- Informational: draft over-generated (excluded from TPC formula)
    COUNTIF(match_status = 'draft_only')                                         AS draft_only_items,
    -- Inflates denominator → reduces TPC (excluded from detail extract)
    COUNTIF(match_status = 'live_only')                                          AS live_only_items,

    -- Description accuracy: only for exactly matched items with descriptions on both sides
    ROUND(AVG(IF(match_status = 'matched' AND desc_overlap_pct IS NOT NULL,
                 desc_overlap_pct, NULL)), 1)                                    AS description_accuracy_pct,

    -- AI description metrics
    COUNTIF(is_ai_description AND match_status = 'matched')                      AS ai_desc_items,
    COUNTIF(is_ai_description AND match_status = 'matched' AND NOT ai_desc_not_retained) AS ai_desc_retained,
    COUNTIF(ai_desc_not_retained AND match_status = 'matched')                   AS ai_desc_not_retained_count
  FROM tmp_item_comparison
  GROUP BY 1, 2, 3
),
option_scores AS (
  SELECT vendor_id, global_entity_id,
    SUM(draft_option_count) AS total_draft_options,
    SUM(live_option_count)  AS total_live_options_matched
  FROM tmp_option_comparison
  GROUP BY 1, 2
)
SELECT
  i.draft_outcome,
  i.vendor_id,
  i.global_entity_id,

  -- Counts
  i.total_draft_items,
  i.total_live_items,
  i.anticipated_items,
  i.exact_matched_items,
  i.live_items_as_draft_options,
  i.draft_items_in_live_options,
  i.draft_only_items,
  i.live_only_items,
  o.total_draft_options,
  o.total_live_options_matched,

  -- Score 1: TPC (matched + live_only_in_draft_as_option count as anticipated)
  ROUND(100.0 * i.anticipated_items / NULLIF(i.total_live_items, 0), 1)          AS total_product_completeness_pct,

  -- Score 2: DA (exact matched items only; [ai] stripped from draft before overlap)
  i.description_accuracy_pct,

  -- Score 3: CA
  ROUND(100.0 * o.total_live_options_matched / NULLIF(o.total_draft_options, 0), 1) AS choice_accuracy_pct,

  -- AI description metrics
  i.ai_desc_items                                                                AS ai_desc_item_count,
  i.ai_desc_items > 0                                                            AS has_ai_descriptions,
  ROUND(100.0 * i.ai_desc_retained / NULLIF(i.ai_desc_items, 0), 1)             AS ai_desc_retention_pct,
  i.ai_desc_not_retained_count,

  -- Composite
  ROUND((
      COALESCE(ROUND(100.0 * i.anticipated_items / NULLIF(i.total_live_items, 0), 1), 0)
    + COALESCE(i.description_accuracy_pct, 0)
    + COALESCE(ROUND(100.0 * o.total_live_options_matched / NULLIF(o.total_draft_options, 0), 1), 0)
  ) / 3.0, 1)                                                                    AS composite_score

FROM item_scores   AS i
  LEFT JOIN option_scores AS o USING (vendor_id, global_entity_id)
ORDER BY i.draft_outcome, composite_score;


-- ================================================================
-- RESULT 2: Item-level extract — one row per actionable item
--
-- Included statuses:
--   matched                    — draft primary ↔ live primary (core comparison)
--   live_only_in_draft_as_option — draft anticipated as option, vendor made standalone
--   draft_item_as_live_option  — draft primary ended up as live choice option (success)
--
-- Excluded from extract (still affect TPC score via Result 1):
--   draft_only  — draft over-generated; no live counterpart; informational noise
--   live_only   — vendor added items the system didn't know about; score impact visible in TPC
-- ================================================================
SELECT
  draft_outcome,
  vendor_id,
  global_entity_id,
  match_status,
  draft_option_parent,
  draft_item_name,
  live_item_name,
  draft_description,
  live_description,
  is_ai_description,
  desc_overlap_pct,
  ai_desc_not_retained
FROM tmp_item_comparison
WHERE match_status IN ('matched', 'live_only_in_draft_as_option', 'draft_item_as_live_option')
ORDER BY
  draft_outcome,
  vendor_id,
  CASE match_status
    WHEN 'matched'                      THEN 1
    WHEN 'live_only_in_draft_as_option' THEN 2
    WHEN 'draft_item_as_live_option'    THEN 3
  END,
  COALESCE(draft_item_name, live_item_name);
