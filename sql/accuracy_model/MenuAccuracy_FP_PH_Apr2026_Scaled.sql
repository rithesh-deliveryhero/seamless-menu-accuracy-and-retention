-- ================================================================
-- MENU ACCURACY MODEL — Scaled
-- FP_PH | Non SSU | Seamless Market | April 2026
-- Population: 473 vendors (559 minus 86 confirmed shared menus)
--
-- RESULT 1: Vendor-level scores (TPC, DA, CA, Composite)
-- RESULT 2: Bucket summary — Drafts Not Retained vs Retained in SF
-- ================================================================

CREATE TEMP FUNCTION clean_text(s STRING) RETURNS STRING AS (
  ARRAY_TO_STRING(
    ARRAY(
      SELECT REGEXP_REPLACE(w, r'[^a-z0-9]', '')
      FROM UNNEST(SPLIT(LOWER(TRIM(COALESCE(s, ''))), ' ')) AS w
      WHERE REGEXP_REPLACE(w, r'[^a-z0-9]', '') NOT IN ('', 'and')
    ),
    ' '
  )
);

-- ================================================================
-- SHARED MENU DETECTION (embedded — same logic as population script)
-- ================================================================
CREATE TEMP TABLE tmp_shared_menu AS (
WITH
menu_cases AS (
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
SELECT
  mc.grid__c,
  mc.global_entity_id,
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
-- PART 1 — Item-level comparison across the clean population
-- ================================================================
CREATE TEMP TABLE tmp_item_comparison AS (
WITH

population AS (
  SELECT
    f.global_entity_id, f.grid_id, f.vendor_id, f.onboarded_date,
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
  SELECT
    c.global_entity_id,
    c.grid__c AS grid,
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
    LOWER(TRIM(item.description)) AS item_description
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
    LEFT JOIN scc_completion AS scc ON ov.vendor_id = scc.vendor_id AND ov.global_entity_id = scc.global_entity_id
    LEFT JOIN menu_case_closed AS mcc ON ov.grid_id = mcc.grid AND ov.global_entity_id = mcc.global_entity_id
    JOIN `fulfillment-dwh-production.curated_data_shared_data_stream.product_stream` AS ps
      ON ps.global_entity_id         = ov.global_entity_id
     AND ps.content.vendor.vendor_id = ov.vendor_id
     AND ps.timestamp BETWEEN
           COALESCE(TIMESTAMP(scc.catalog_created_at), TIMESTAMP(mcc.menu_submitted_at))
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

matched_pairs AS (
  SELECT DISTINCT di.vendor_id, di.global_entity_id,
    di.item_name        AS draft_item_name,
    li.item_name        AS live_item_name,
    di.item_description AS draft_description,
    li.live_desc        AS live_description,
    CASE
      WHEN li.item_name IS NULL        THEN 'draft_only'
      WHEN di.item_name = li.item_name THEN 'matched_exact'
      ELSE                              'matched_fuzzy'
    END AS match_status,
    ROUND(
      SAFE_DIVIDE(
        (SELECT COUNT(1) FROM UNNEST(SPLIT(clean_text(di.item_description), ' ')) AS w1
         WHERE w1 != '' AND w1 IN UNNEST(SPLIT(clean_text(li.live_desc), ' '))),
        (SELECT COUNT(1) FROM UNNEST(SPLIT(clean_text(di.item_description), ' ')) AS w2
         WHERE w2 != '')
      ) * 100, 1
    ) AS desc_overlap_pct
  FROM draft_menu_items AS di
  LEFT JOIN live_menu AS li
    ON di.vendor_id        = li.vendor_id
   AND di.global_entity_id = li.global_entity_id
   AND (
       di.item_name = li.item_name
     OR SAFE_DIVIDE(
          EDIT_DISTANCE(di.item_name, li.item_name),
          GREATEST(CHAR_LENGTH(di.item_name), CHAR_LENGTH(li.item_name))
        ) <= 0.35
   )
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY di.vendor_id, di.global_entity_id, di.item_name
    ORDER BY EDIT_DISTANCE(di.item_name, COALESCE(li.item_name, '')) ASC
  ) = 1
)

-- Draft items (modes 1 & 2)
SELECT vendor_id, global_entity_id, draft_item_name, live_item_name,
  match_status, CAST(NULL AS STRING) AS draft_option_parent, desc_overlap_pct
FROM matched_pairs

UNION ALL

-- Live items not in draft (mode 3)
SELECT li.vendor_id, li.global_entity_id, CAST(NULL AS STRING), li.item_name,
  CASE WHEN dopt.option_name IS NOT NULL THEN 'live_only_in_draft_as_option' ELSE 'live_only' END,
  dopt.parent_item_name, CAST(NULL AS FLOAT64)
FROM live_menu AS li
  LEFT JOIN matched_pairs AS mp
    ON li.vendor_id = mp.vendor_id AND li.global_entity_id = mp.global_entity_id AND li.item_name = mp.live_item_name
  LEFT JOIN draft_options AS dopt
    ON li.vendor_id = dopt.vendor_id AND li.global_entity_id = dopt.global_entity_id AND li.item_name = dopt.option_name
WHERE mp.live_item_name IS NULL
);


-- ================================================================
-- PART 2 — Option-level comparison across the clean population
-- ================================================================
CREATE TEMP TABLE tmp_option_comparison AS (
WITH

population AS (
  SELECT f.global_entity_id, f.grid_id, f.vendor_id,
    CASE
      WHEN f.is_funnel_drafts_not_retained = TRUE THEN 'Drafts Not Retained'
      WHEN f.is_funnel_retained_in_sf      = TRUE THEN 'Retained in SF'
    END AS draft_outcome
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
  SELECT DISTINCT
    ps.content.vendor.vendor_id       AS vendor_id,
    ps.global_entity_id,
    LOWER(TRIM(ps.content.name))       AS option_name
  FROM population AS ov
    JOIN sf_activation AS sfa ON ov.grid_id = sfa.grid AND ov.global_entity_id = sfa.global_entity_id
    LEFT JOIN scc_completion AS scc ON ov.vendor_id = scc.vendor_id AND ov.global_entity_id = scc.global_entity_id
    LEFT JOIN menu_case_closed AS mcc ON ov.grid_id = mcc.grid AND ov.global_entity_id = mcc.global_entity_id
    JOIN `fulfillment-dwh-production.curated_data_shared_data_stream.product_stream` AS ps
      ON ps.global_entity_id         = ov.global_entity_id
     AND ps.content.vendor.vendor_id = ov.vendor_id
     AND ps.timestamp BETWEEN
           COALESCE(TIMESTAMP(scc.catalog_created_at), TIMESTAMP(mcc.menu_submitted_at))
           AND TIMESTAMP(sfa.sf_active_at)
     AND ps.created_date >= DATE_SUB(CURRENT_DATE, INTERVAL 2 MONTH)
    , UNNEST(ps.content.attributes) AS attr
  WHERE NOT COALESCE(ps.content.deleted, FALSE)
    AND STARTS_WITH(attr.name, 'Choice_')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ps.content.vendor.vendor_id, ps.global_entity_id, LOWER(TRIM(ps.content.name)), attr.name
    ORDER BY ps.content.timestamp
  ) = 1
)

SELECT
  dopt.vendor_id, dopt.global_entity_id,
  COUNT(DISTINCT dopt.option_name)  AS draft_option_count,
  COUNT(DISTINCT lo.option_name)    AS live_option_count
FROM draft_options AS dopt
  LEFT JOIN live_options AS lo
    ON dopt.vendor_id        = lo.vendor_id
   AND dopt.global_entity_id = lo.global_entity_id
   AND dopt.option_name      = lo.option_name
GROUP BY 1, 2
);


-- ================================================================
-- RESULT 1: Vendor-level scores
-- ================================================================
WITH
item_scores AS (
  SELECT
    ic.vendor_id, ic.global_entity_id,
    CASE WHEN f.is_funnel_drafts_not_retained = TRUE THEN 'Drafts Not Retained' WHEN f.is_funnel_retained_in_sf = TRUE THEN 'Retained in SF' END AS draft_outcome,
    COUNT(DISTINCT ic.live_item_name)                                                            AS total_live_items,
    COUNT(DISTINCT ic.draft_item_name)                                                           AS total_draft_items,
    COUNTIF(ic.match_status IN ('matched_exact', 'matched_fuzzy'))                               AS matched_items,
    ROUND(AVG(IF(ic.match_status IN ('matched_exact', 'matched_fuzzy') AND ic.desc_overlap_pct IS NOT NULL,
                 ic.desc_overlap_pct, NULL)), 1)                                                 AS description_accuracy_pct
  FROM tmp_item_comparison AS ic
  JOIN `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel` AS f
    ON ic.vendor_id = f.vendor_id AND ic.global_entity_id = f.global_entity_id
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
  i.vendor_id, i.global_entity_id, i.draft_outcome,
  i.total_draft_items, i.total_live_items, i.matched_items,
  o.total_draft_options, o.total_live_options_matched,
  ROUND(100.0 * i.matched_items / NULLIF(i.total_live_items, 0), 1)                           AS total_product_completeness_pct,
  i.description_accuracy_pct,
  ROUND(100.0 * o.total_live_options_matched / NULLIF(o.total_draft_options, 0), 1)           AS choice_accuracy_pct,
  ROUND((
      COALESCE(ROUND(100.0 * i.matched_items / NULLIF(i.total_live_items, 0), 1), 0)
    + COALESCE(i.description_accuracy_pct, 0)
    + COALESCE(ROUND(100.0 * o.total_live_options_matched / NULLIF(o.total_draft_options, 0), 1), 0)
  ) / 3.0, 1)                                                                                  AS composite_score
FROM item_scores   AS i
  LEFT JOIN option_scores AS o USING (vendor_id, global_entity_id)
ORDER BY i.draft_outcome, composite_score;


-- ================================================================
-- RESULT 2: Bucket summary — item-count weighted averages
-- ================================================================
WITH
item_scores AS (
  SELECT
    ic.vendor_id, ic.global_entity_id,
    CASE WHEN f.is_funnel_drafts_not_retained = TRUE THEN 'Drafts Not Retained' WHEN f.is_funnel_retained_in_sf = TRUE THEN 'Retained in SF' END AS draft_outcome,
    COUNT(DISTINCT ic.live_item_name)                                                            AS total_live_items,
    COUNTIF(ic.match_status IN ('matched_exact', 'matched_fuzzy'))                               AS matched_items,
    ROUND(AVG(IF(ic.match_status IN ('matched_exact', 'matched_fuzzy') AND ic.desc_overlap_pct IS NOT NULL,
                 ic.desc_overlap_pct, NULL)), 1)                                                 AS description_accuracy_pct
  FROM tmp_item_comparison AS ic
  JOIN `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel` AS f
    ON ic.vendor_id = f.vendor_id AND ic.global_entity_id = f.global_entity_id
  GROUP BY 1, 2, 3
),
option_scores AS (
  SELECT vendor_id, global_entity_id,
    SUM(draft_option_count) AS total_draft_options,
    SUM(live_option_count)  AS total_live_options_matched
  FROM tmp_option_comparison
  GROUP BY 1, 2
),
vendor_scores AS (
  SELECT
    i.vendor_id, i.global_entity_id, i.draft_outcome,
    i.total_live_items, i.matched_items,
    o.total_draft_options, o.total_live_options_matched,
    ROUND(100.0 * i.matched_items / NULLIF(i.total_live_items, 0), 1)                         AS tpc,
    i.description_accuracy_pct                                                                  AS da,
    ROUND(100.0 * o.total_live_options_matched / NULLIF(o.total_draft_options, 0), 1)          AS ca
  FROM item_scores AS i
    LEFT JOIN option_scores AS o USING (vendor_id, global_entity_id)
)
SELECT
  draft_outcome,
  COUNT(DISTINCT vendor_id)                                                  AS vendor_count,
  SUM(total_live_items)                                                      AS total_live_items,
  SUM(matched_items)                                                         AS total_matched_items,
  SUM(total_draft_options)                                                   AS total_draft_options,
  SUM(total_live_options_matched)                                            AS total_live_options_matched,

  -- Weighted averages (weight = item/option count so larger menus count more)
  ROUND(SUM(tpc * total_live_items)          / NULLIF(SUM(total_live_items), 0), 1)            AS tpc_weighted_avg,
  ROUND(SUM(da  * matched_items)             / NULLIF(SUM(matched_items), 0), 1)               AS da_weighted_avg,
  ROUND(SUM(ca  * total_draft_options)       / NULLIF(SUM(total_draft_options), 0), 1)         AS ca_weighted_avg,
  ROUND((
      SUM(tpc * total_live_items)      / NULLIF(SUM(total_live_items), 0)
    + SUM(da  * matched_items)         / NULLIF(SUM(matched_items), 0)
    + SUM(ca  * total_draft_options)   / NULLIF(SUM(total_draft_options), 0)
  ) / 3.0, 1)                                                                                  AS composite_weighted_avg

FROM vendor_scores
GROUP BY draft_outcome
ORDER BY draft_outcome;
