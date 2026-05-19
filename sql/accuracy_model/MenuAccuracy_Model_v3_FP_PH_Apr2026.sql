-- ================================================================
-- MENU ACCURACY MODEL v3  (verified on BQ 2026-05-19)
-- FP_PH | Non SSU | Seamless Market | April 2026 | 473 clean vendors
--
-- Three independent metrics (no composite score):
--
--   TPC  — Total Product Completeness
--          Bidirectional word-overlap name matching (≥60% both directions)
--          Exact match preferred; fuzzy as fallback
--          Primary items only — choice groups / options fully excluded
--          TPC = matched / total_live_items
--
--   DA   — Description Accuracy (non-AI descriptions only)
--          [ai]-tagged draft descriptions excluded from both numerator
--          and denominator — not a failure, tracked separately via ADAR
--          DA = avg word-overlap for non-AI matched items with descriptions
--
--   ADAR — AI Description Adoption Rate (new metric)
--          Of AI-tagged descriptions that made it onto a matched item,
--          what % was retained in live (word overlap ≥ 60%)?
--
-- Results:
--   RESULT 1 — Vendor-level scores
--   RESULT 2 — Bucket summary (weighted averages)
--   RESULT 3 — Item-level detail
--
-- April 2026 FP_PH results (verified):
--   Not Retained (220 vendors): TPC 69.1% | DA 85.0% | ADAR 0.2%
--   Retained     (187 vendors): TPC 78.9% | DA 87.9% | ADAR 1.1%
-- ================================================================

CREATE TEMP FUNCTION clean_text(s STRING) RETURNS STRING AS (
  -- Normalises: lowercase, strip punctuation per word, drop "and"
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
-- Core data CTEs
-- ================================================================
CREATE TEMP TABLE tmp_best_match AS (
WITH

population AS (
  SELECT f.global_entity_id, f.grid_id, f.vendor_id,
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

-- Primary draft items only (no options/choice groups)
draft_items AS (
  SELECT DISTINCT dm.vendor_id, dm.global_entity_id,
    LOWER(TRIM(item.name))        AS iname,
    LOWER(TRIM(item.description)) AS idesc,
    REGEXP_CONTAINS(LOWER(TRIM(COALESCE(item.description, ''))), r'\[ai\]') AS is_ai
  FROM `dh-central-salesforce-tech.dh_salesforce_scc_draft_menu.dh_salesforce_draft_menu` AS dm
    , UNNEST(dm.items) AS item
  WHERE dm.vendor_id IN (SELECT vendor_id FROM population)
    AND dm.global_entity_id = 'FP_PH'
    AND CHAR_LENGTH(item.name) > 0
),

-- Primary live items only (Choice_* excluded via attribute filter)
live_items AS (
  SELECT DISTINCT
    ps.content.vendor.vendor_id        AS vendor_id,
    ps.global_entity_id,
    LOWER(TRIM(ps.content.name))        AS iname,
    LOWER(TRIM(ps.content.description)) AS ldesc
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

-- Word counts per item name (denominators for coverage ratios)
draft_wc AS (
  SELECT vendor_id, global_entity_id, iname, COUNT(DISTINCT w) AS wc
  FROM draft_items, UNNEST(SPLIT(clean_text(iname), ' ')) AS w
  WHERE w != '' GROUP BY 1, 2, 3
),
live_wc AS (
  SELECT vendor_id, global_entity_id, iname, COUNT(DISTINCT w) AS wc
  FROM live_items, UNNEST(SPLIT(clean_text(iname), ' ')) AS w
  WHERE w != '' GROUP BY 1, 2, 3
),

-- ----------------------------------------------------------------
-- Word-level join: only pairs sharing ≥1 word (avoids full cross-product)
-- Then apply bidirectional ≥60% coverage filter.
-- This is what prevents wrong-protein ("beef burger" ≠ "chicken burger")
-- and single-word traps ("chicken" ≠ "chicken wings").
-- ----------------------------------------------------------------
word_pairs AS (
  SELECT dw.vendor_id, dw.global_entity_id, dw.iname AS di, lw.iname AS li,
    COUNT(DISTINCT dw.w) AS shared
  FROM (SELECT vendor_id, global_entity_id, iname, w
        FROM draft_items, UNNEST(SPLIT(clean_text(iname), ' ')) AS w WHERE w != '') dw
  JOIN (SELECT vendor_id, global_entity_id, iname, w
        FROM live_items, UNNEST(SPLIT(clean_text(iname), ' ')) AS w WHERE w != '') lw
    ON dw.vendor_id = lw.vendor_id AND dw.global_entity_id = lw.global_entity_id AND dw.w = lw.w
  GROUP BY 1, 2, 3, 4
),

-- Best live match per draft item: exact preferred, then highest avg bidirectional coverage
best_match AS (
  SELECT
    dwc.vendor_id, dwc.global_entity_id,
    dwc.iname                              AS draft_item,
    wp.li                                  AS live_item,
    ROUND(SAFE_DIVIDE(wp.shared, dwc.wc) * 100, 0) AS draft_cov_pct,
    ROUND(SAFE_DIVIDE(wp.shared, lwc.wc) * 100, 0) AS live_cov_pct
  FROM draft_wc AS dwc
  JOIN word_pairs AS wp  ON dwc.vendor_id = wp.vendor_id AND dwc.global_entity_id = wp.global_entity_id AND dwc.iname = wp.di
  JOIN live_wc   AS lwc  ON wp.vendor_id  = lwc.vendor_id AND wp.global_entity_id  = lwc.global_entity_id AND wp.li = lwc.iname
  WHERE SAFE_DIVIDE(wp.shared, dwc.wc) >= 0.6
    AND SAFE_DIVIDE(wp.shared, lwc.wc) >= 0.6
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY dwc.vendor_id, dwc.global_entity_id, dwc.iname
    ORDER BY (SAFE_DIVIDE(wp.shared, dwc.wc) + SAFE_DIVIDE(wp.shared, lwc.wc)) / 2 DESC
  ) = 1
)

-- Materialise draft ↔ live pairs (one row per draft item)
SELECT
  pop.draft_outcome,
  di.vendor_id, di.global_entity_id,
  di.iname  AS draft_item,
  bm.live_item,
  di.idesc  AS draft_description,
  li.ldesc  AS live_description,
  di.is_ai  AS is_ai_description,
  bm.draft_cov_pct, bm.live_cov_pct,
  CASE
    WHEN bm.live_item IS NULL                                 THEN 'draft_only'
    WHEN clean_text(di.iname) = clean_text(bm.live_item)     THEN 'matched_exact'
    ELSE                                                       'matched_fuzzy'
  END AS match_status,
  -- Description overlap ([ai] stripped from draft before comparison)
  ROUND(SAFE_DIVIDE(
    (SELECT COUNT(1) FROM UNNEST(SPLIT(clean_desc(di.idesc), ' ')) AS w1
     WHERE w1 != '' AND w1 IN UNNEST(SPLIT(clean_text(li.ldesc), ' '))),
    NULLIF((SELECT COUNT(1) FROM UNNEST(SPLIT(clean_desc(di.idesc), ' ')) AS w2 WHERE w2 != ''), 0)
  ) * 100, 1) AS desc_overlap_pct
FROM draft_items AS di
JOIN population AS pop ON di.vendor_id = pop.vendor_id AND di.global_entity_id = pop.global_entity_id
LEFT JOIN best_match AS bm ON di.vendor_id = bm.vendor_id AND di.global_entity_id = bm.global_entity_id AND di.iname = bm.draft_item
LEFT JOIN live_items AS li ON bm.vendor_id = li.vendor_id AND bm.global_entity_id = li.global_entity_id AND bm.live_item = li.iname
);

-- Materialise live-only items (separate table to avoid row-multiplication in aggregation)
CREATE TEMP TABLE tmp_live_only AS (
WITH
population AS (
  SELECT f.global_entity_id, f.grid_id, f.vendor_id,
    CASE WHEN f.is_funnel_drafts_not_retained THEN 'Drafts Not Retained' ELSE 'Retained in SF' END AS draft_outcome
  FROM `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel` AS f
  LEFT JOIN tmp_shared_menu AS sm ON f.grid_id = sm.grid__c AND f.global_entity_id = sm.global_entity_id
  WHERE f.global_entity_id = 'FP_PH' AND f.onboard_month = '2026-04-01'
    AND f.account_source_curated = 'Non SSU' AND f.is_seamless_market = TRUE
    AND (f.is_funnel_drafts_not_retained OR f.is_funnel_retained_in_sf)
    AND COALESCE(sm.is_shared_menu, FALSE) = FALSE
),
menu_case_closed AS (SELECT c.global_entity_id,c.grid__c AS grid,ARRAY_REVERSE(SPLIT(REGEXP_REPLACE(TRIM(c.backend_id__c),r"[^a-zA-Z0-9\s]+","-"),"-"))[SAFE_OFFSET(0)] AS vendor_id,MIN(c.closeddate) AS msat FROM `fulfillment-dwh-production.curated_data_shared_salesforce.case` c WHERE c.type='Menu Processing' AND c.status='Closed' AND c.global_entity_id='FP_PH' AND DATE(c.closeddate)>=DATE_TRUNC(DATE_SUB(CURRENT_DATE,INTERVAL 12 MONTH),MONTH) AND c.grid__c IN(SELECT grid_id FROM population) GROUP BY 1,2,3),
sf_activation AS (SELECT a.global_entity_id,a.grid__c AS grid,MIN(ah.createddate) AS saat FROM `fulfillment-dwh-production.curated_data_shared_salesforce.account_history` ah JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.account` a ON ah.accountid=a.id AND ah.global_entity_id=a.global_entity_id WHERE ah.field='Account_Status__c' AND ah.newvalue='Active' AND a.global_entity_id='FP_PH' AND a.grid__c IN(SELECT grid_id FROM population) AND DATE(ah.createddate)>=DATE_TRUNC(DATE_SUB(CURRENT_DATE,INTERVAL 13 MONTH),MONTH) GROUP BY 1,2),
scc_completion AS (SELECT job.vendor_id,job.global_entity_id,MIN(job.timestamp) AS cat FROM `dh-central-salesforce-tech.dh_salesforce_scc_draft_menu.dh_salesforce_scc_job_info` job JOIN menu_case_closed mcc ON job.vendor_id=mcc.vendor_id AND job.global_entity_id=mcc.global_entity_id WHERE job.status='Completed' AND job.type='gms-products' AND TIMESTAMP_DIFF(job.timestamp,mcc.msat,HOUR) BETWEEN -168 AND 744 GROUP BY 1,2),
live_items AS (SELECT DISTINCT ps.content.vendor.vendor_id AS vendor_id,ps.global_entity_id,LOWER(TRIM(ps.content.name)) AS iname,LOWER(TRIM(ps.content.description)) AS ldesc FROM population ov JOIN sf_activation sfa ON ov.grid_id=sfa.grid AND ov.global_entity_id=sfa.global_entity_id LEFT JOIN menu_case_closed mcc ON ov.grid_id=mcc.grid AND ov.global_entity_id=mcc.global_entity_id LEFT JOIN scc_completion scc ON ov.vendor_id=scc.vendor_id AND ov.global_entity_id=scc.global_entity_id JOIN `fulfillment-dwh-production.curated_data_shared_data_stream.product_stream` ps ON ps.global_entity_id=ov.global_entity_id AND ps.content.vendor.vendor_id=ov.vendor_id AND ps.timestamp BETWEEN COALESCE(TIMESTAMP(mcc.msat),TIMESTAMP(scc.cat)) AND TIMESTAMP(sfa.saat) AND ps.created_date>=DATE_SUB(CURRENT_DATE,INTERVAL 2 MONTH) WHERE NOT COALESCE(ps.content.deleted,FALSE) AND NOT EXISTS(SELECT 1 FROM UNNEST(ps.content.attributes) attr WHERE attr.name='_Choices' OR STARTS_WITH(attr.name,'Choice_')) QUALIFY ROW_NUMBER() OVER(PARTITION BY ps.content.vendor.vendor_id,ps.global_entity_id,LOWER(TRIM(ps.content.name)) ORDER BY ps.content.timestamp)=1)
SELECT li.vendor_id, pop.draft_outcome, li.iname AS live_item, li.ldesc AS live_description
FROM live_items AS li
JOIN population AS pop ON li.vendor_id = pop.vendor_id AND li.global_entity_id = pop.global_entity_id
LEFT JOIN tmp_best_match AS bm ON li.vendor_id = bm.vendor_id AND li.global_entity_id = bm.global_entity_id AND li.iname = bm.live_item
WHERE bm.live_item IS NULL
);


-- ================================================================
-- RESULT 1: Vendor-level scores
-- Aggregated from two separate tables to prevent row multiplication
-- ================================================================
WITH
draft_agg AS (
  SELECT vendor_id, global_entity_id, draft_outcome,
    COUNT(DISTINCT draft_item)                                                                       AS n_draft,
    COUNT(DISTINCT CASE WHEN match_status IN ('matched_exact','matched_fuzzy') THEN draft_item END)  AS matched,
    COUNT(DISTINCT CASE WHEN match_status = 'matched_exact' THEN draft_item END)                     AS exact_matches,
    COUNT(DISTINCT CASE WHEN match_status = 'matched_fuzzy' THEN draft_item END)                     AS fuzzy_matches,
    -- DA: non-AI items with descriptions (excluded from both sides when AI)
    ROUND(AVG(IF(match_status IN ('matched_exact','matched_fuzzy') AND NOT is_ai_description
                 AND desc_overlap_pct IS NOT NULL, desc_overlap_pct, NULL)), 1)                      AS description_accuracy_pct,
    COUNT(DISTINCT CASE WHEN match_status IN ('matched_exact','matched_fuzzy')
                        AND NOT is_ai_description AND desc_overlap_pct IS NOT NULL
                        THEN draft_item END)                                                          AS da_items_evaluated,
    -- ADAR: AI items
    COUNT(DISTINCT CASE WHEN match_status IN ('matched_exact','matched_fuzzy')
                        AND is_ai_description THEN draft_item END)                                   AS ai_desc_item_count,
    COUNT(DISTINCT CASE WHEN match_status IN ('matched_exact','matched_fuzzy')
                        AND is_ai_description AND COALESCE(desc_overlap_pct, 0) >= 60
                        THEN draft_item END)                                                          AS ai_desc_adopted_count
  FROM tmp_best_match
  GROUP BY 1, 2, 3
),
live_agg AS (
  SELECT vendor_id, draft_outcome,
    COUNT(DISTINCT live_item) AS n_live_only
  FROM tmp_live_only
  GROUP BY 1, 2
),
live_matched_agg AS (
  SELECT vendor_id, global_entity_id, draft_outcome,
    COUNT(DISTINCT live_item) AS n_live_matched
  FROM tmp_best_match WHERE live_item IS NOT NULL
  GROUP BY 1, 2, 3
)
SELECT
  da.draft_outcome,
  da.vendor_id,
  da.global_entity_id,
  da.n_draft                                                                                   AS total_draft_items,
  COALESCE(lm.n_live_matched, 0) + COALESCE(lo.n_live_only, 0)                                AS total_live_items,
  da.matched                                                                                   AS matched_items,
  da.exact_matches,
  da.fuzzy_matches,
  da.n_draft - da.matched                                                                      AS draft_only_items,
  COALESCE(lo.n_live_only, 0)                                                                  AS live_only_items,
  -- TPC
  ROUND(100.0 * da.matched / NULLIF(COALESCE(lm.n_live_matched, 0) + COALESCE(lo.n_live_only, 0), 0), 1) AS total_product_completeness_pct,
  -- DA (non-AI only)
  da.description_accuracy_pct,
  da.da_items_evaluated,
  -- ADAR
  da.ai_desc_item_count,
  da.ai_desc_adopted_count,
  ROUND(100.0 * da.ai_desc_adopted_count / NULLIF(da.ai_desc_item_count, 0), 1)               AS ai_desc_adoption_pct,
  da.ai_desc_item_count > 0                                                                    AS has_ai_descriptions
FROM draft_agg AS da
  LEFT JOIN live_matched_agg AS lm USING (vendor_id, global_entity_id, draft_outcome)
  LEFT JOIN live_agg         AS lo ON da.vendor_id = lo.vendor_id AND da.draft_outcome = lo.draft_outcome
ORDER BY da.draft_outcome, total_product_completeness_pct;


-- ================================================================
-- RESULT 2: Bucket-level weighted summary
-- ================================================================
WITH
draft_agg AS (
  SELECT vendor_id, draft_outcome,
    COUNT(DISTINCT draft_item) AS n_draft,
    COUNT(DISTINCT CASE WHEN match_status IN ('matched_exact','matched_fuzzy') THEN draft_item END) AS matched,
    COUNT(DISTINCT CASE WHEN match_status = 'matched_exact' THEN draft_item END) AS exact,
    COUNT(DISTINCT CASE WHEN match_status = 'matched_fuzzy' THEN draft_item END) AS fuzzy,
    ROUND(AVG(IF(match_status IN ('matched_exact','matched_fuzzy') AND NOT is_ai_description AND desc_overlap_pct IS NOT NULL, desc_overlap_pct, NULL)), 1) AS da,
    COUNT(DISTINCT CASE WHEN match_status IN ('matched_exact','matched_fuzzy') AND NOT is_ai_description AND desc_overlap_pct IS NOT NULL THEN draft_item END) AS da_items,
    COUNT(DISTINCT CASE WHEN match_status IN ('matched_exact','matched_fuzzy') AND is_ai_description THEN draft_item END) AS ai_items,
    ROUND(100.0 * COUNT(DISTINCT CASE WHEN match_status IN ('matched_exact','matched_fuzzy') AND is_ai_description AND COALESCE(desc_overlap_pct,0)>=60 THEN draft_item END) / NULLIF(COUNT(DISTINCT CASE WHEN match_status IN ('matched_exact','matched_fuzzy') AND is_ai_description THEN draft_item END), 0), 1) AS adar
  FROM tmp_best_match GROUP BY 1, 2
),
live_agg AS (
  SELECT vendor_id, draft_outcome, COUNT(DISTINCT live_item) AS n_live_only FROM tmp_live_only GROUP BY 1, 2
),
live_matched_agg AS (
  SELECT vendor_id, draft_outcome, COUNT(DISTINCT live_item) AS n_live_matched FROM tmp_best_match WHERE live_item IS NOT NULL GROUP BY 1, 2
),
vendor_scores AS (
  SELECT da.vendor_id, da.draft_outcome,
    da.n_draft, da.matched, da.exact, da.fuzzy,
    COALESCE(lm.n_live_matched, 0) + COALESCE(lo.n_live_only, 0) AS n_live,
    COALESCE(lo.n_live_only, 0) AS n_live_only,
    ROUND(100.0 * da.matched / NULLIF(COALESCE(lm.n_live_matched,0)+COALESCE(lo.n_live_only,0), 0), 1) AS tpc,
    da.da, da.da_items, da.ai_items, da.adar
  FROM draft_agg da
  LEFT JOIN live_matched_agg lm ON da.vendor_id = lm.vendor_id AND da.draft_outcome = lm.draft_outcome
  LEFT JOIN live_agg         lo ON da.vendor_id = lo.vendor_id AND da.draft_outcome = lo.draft_outcome
)
SELECT
  draft_outcome,
  COUNT(DISTINCT vendor_id)                                                          AS vendors,
  SUM(n_draft)   AS total_draft,  SUM(n_live)    AS total_live,
  SUM(matched)   AS matched,      SUM(exact)     AS exact,   SUM(fuzzy)  AS fuzzy,
  SUM(n_draft) - SUM(matched) AS draft_only,  SUM(n_live_only) AS live_only,
  SUM(da_items)  AS da_items_evaluated,       SUM(ai_items) AS ai_desc_items,
  ROUND(SUM(tpc * n_live)   / NULLIF(SUM(n_live), 0), 1)    AS tpc_weighted_avg,
  ROUND(SUM(da  * da_items) / NULLIF(SUM(da_items), 0), 1)  AS da_weighted_avg,
  ROUND(SUM(adar * ai_items)/ NULLIF(SUM(ai_items), 0), 1)  AS adar_weighted_avg
FROM vendor_scores
GROUP BY draft_outcome
ORDER BY draft_outcome;


-- ================================================================
-- RESULT 3: Item-level detail
-- Includes matched (exact/fuzzy), draft_only, live_only
-- ================================================================
SELECT
  draft_outcome, vendor_id, global_entity_id, match_status,
  draft_item, live_item, draft_cov_pct, live_cov_pct,
  draft_description, live_description,
  is_ai_description, desc_overlap_pct,
  NOT is_ai_description AND match_status IN ('matched_exact','matched_fuzzy')
    AND COALESCE(desc_overlap_pct, 0) < 60                                        AS non_ai_desc_rewritten,
  is_ai_description AND match_status IN ('matched_exact','matched_fuzzy')
    AND COALESCE(desc_overlap_pct, 0) >= 60                                        AS ai_desc_adopted
FROM tmp_best_match

UNION ALL

SELECT
  draft_outcome, vendor_id, global_entity_id,
  'live_only' AS match_status,
  CAST(NULL AS STRING) AS draft_item,
  live_item,
  CAST(NULL AS FLOAT64) AS draft_cov_pct,
  CAST(NULL AS FLOAT64) AS live_cov_pct,
  CAST(NULL AS STRING) AS draft_description,
  live_description,
  FALSE AS is_ai_description,
  CAST(NULL AS FLOAT64) AS desc_overlap_pct,
  FALSE AS non_ai_desc_rewritten,
  FALSE AS ai_desc_adopted
FROM tmp_live_only

ORDER BY draft_outcome, vendor_id,
  CASE match_status WHEN 'matched_exact' THEN 1 WHEN 'matched_fuzzy' THEN 2
                    WHEN 'draft_only' THEN 3 WHEN 'live_only' THEN 4 END,
  COALESCE(draft_item, live_item);
