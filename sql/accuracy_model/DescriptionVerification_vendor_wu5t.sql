-- ================================================================
-- MENU ACCURACY MODEL — vendor: wu5t (FP_PH)
--
-- Three scores, each 0–100%:
--   1. Total Product Completeness (TPC) = matched items / total live items
--   2. Description Accuracy       (DA)  = avg clean word-overlap for matched items
--   3. Choice Accuracy            (CA)  = draft options present in live / total draft options
--   Composite = equal 1/3 weight (adjust in Result 3 if needed)
--
-- clean_text(): strips punctuation per word + removes "and" noise
-- Item names: fuzzy-matched via edit distance (threshold 35% of max name length)
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
-- PART 1 — Item-level comparison (primary menu items only)
-- ================================================================
CREATE TEMP TABLE tmp_item_comparison AS (
WITH

menu_case_closed AS (
  SELECT
    c.global_entity_id,
    ARRAY_REVERSE(SPLIT(REGEXP_REPLACE(TRIM(c.backend_id__c), r"[^a-zA-Z0-9\s]+", "-"), "-"))[SAFE_OFFSET(0)] AS vendor_id,
    MIN(c.closeddate) AS menu_submitted_at
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.case` AS c
  WHERE c.type = 'Menu Processing' AND c.status = 'Closed'
    AND DATE(c.closeddate) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH), MONTH)
    AND ARRAY_REVERSE(SPLIT(REGEXP_REPLACE(TRIM(c.backend_id__c), r"[^a-zA-Z0-9\s]+", "-"), "-"))[SAFE_OFFSET(0)] = "wu5t"
  GROUP BY 1, 2
),

sf_activation AS (
  SELECT a.global_entity_id, a.grid__c AS grid, MIN(ah.createddate) AS sf_active_at
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.account_history` AS ah
    JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.account` AS a
      ON ah.accountid = a.id AND ah.global_entity_id = a.global_entity_id
  WHERE ah.field = 'Account_Status__c' AND ah.newvalue = 'Active'
    AND a.global_entity_id = "FP_PH" AND a.grid__c = "HTA5NP"
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
  WHERE dm.vendor_id = "wu5t" AND CHAR_LENGTH(item.name) > 0
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
  WHERE dm.vendor_id = "wu5t"
    AND CHAR_LENGTH(item.name) > 0
    AND JSON_VALUE(sel, '$.selection_name') IS NOT NULL
),

live_menu AS (
  SELECT DISTINCT
    ps.content.vendor.vendor_id        AS vendor_id,
    ps.global_entity_id,
    LOWER(TRIM(ps.content.name))        AS item_name,
    LOWER(TRIM(ps.content.description)) AS live_desc
  FROM `fulfillment-dwh-production.curated_data_shared_data_stream.product_stream` AS ps
    JOIN sf_activation AS sfa ON sfa.global_entity_id = ps.global_entity_id
    LEFT JOIN scc_completion AS scc
      ON scc.vendor_id = ps.content.vendor.vendor_id AND scc.global_entity_id = ps.global_entity_id
    LEFT JOIN menu_case_closed AS mcc
      ON mcc.vendor_id = ps.content.vendor.vendor_id AND mcc.global_entity_id = ps.global_entity_id
  WHERE ps.global_entity_id = "FP_PH"
    AND ps.content.vendor.vendor_id = "wu5t"
    AND ps.created_date >= DATE_SUB(CURRENT_DATE, INTERVAL 2 MONTH)
    AND ps.timestamp BETWEEN
          COALESCE(TIMESTAMP(scc.catalog_created_at), TIMESTAMP(mcc.menu_submitted_at))
          AND TIMESTAMP(sfa.sf_active_at)
    AND NOT COALESCE(ps.content.deleted, FALSE)
    AND NOT EXISTS (
      SELECT 1 FROM UNNEST(ps.content.attributes) AS attr
      WHERE attr.name = '_Choices' OR STARTS_WITH(attr.name, 'Choice_')
    )
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ps.content.vendor.vendor_id, ps.global_entity_id, LOWER(TRIM(ps.content.name))
    ORDER BY ps.content.timestamp
  ) = 1
),

-- Best live match per draft item: exact first, then closest fuzzy (edit dist ≤ 35% of max name length).
-- QUALIFY keeps only the single best match per draft item.
matched_pairs AS (
  SELECT DISTINCT di.vendor_id, di.global_entity_id,
    di.item_name        AS draft_item_name,
    li.item_name        AS live_item_name,
    di.item_description AS draft_description,
    li.live_desc        AS live_description,
    CASE
      WHEN li.item_name IS NULL      THEN 'draft_only'
      WHEN di.item_name = li.item_name THEN 'matched_exact'
      ELSE                             'matched_fuzzy'
    END AS match_status,
    ROUND(
      SAFE_DIVIDE(
        EDIT_DISTANCE(di.item_name, COALESCE(li.item_name, '')),
        GREATEST(CHAR_LENGTH(di.item_name), CHAR_LENGTH(COALESCE(li.item_name, di.item_name)))
      ) * 100, 1
    ) AS name_edit_dist_pct,
    -- clean_text removes punctuation & "and"/"&" before word-overlap scoring
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

-- Failure modes 1 & 2: every draft item (matched_exact / matched_fuzzy / draft_only)
SELECT vendor_id, global_entity_id, draft_item_name, live_item_name, match_status,
  CAST(NULL AS STRING)  AS draft_option_parent,
  draft_description, live_description, name_edit_dist_pct, desc_overlap_pct
FROM matched_pairs

UNION ALL

-- Failure mode 3: live items the draft missed entirely
-- sub-classified: was it at least a nested option in the draft?
SELECT
  li.vendor_id, li.global_entity_id,
  CAST(NULL AS STRING)  AS draft_item_name,
  li.item_name          AS live_item_name,
  CASE WHEN dopt.option_name IS NOT NULL THEN 'live_only_in_draft_as_option' ELSE 'live_only' END AS match_status,
  dopt.parent_item_name AS draft_option_parent,
  CAST(NULL AS STRING)  AS draft_description,
  li.live_desc          AS live_description,
  CAST(NULL AS FLOAT64) AS name_edit_dist_pct,
  CAST(NULL AS FLOAT64) AS desc_overlap_pct
FROM live_menu AS li
  LEFT JOIN matched_pairs AS mp
    ON li.vendor_id        = mp.vendor_id
   AND li.global_entity_id = mp.global_entity_id
   AND li.item_name        = mp.live_item_name
  LEFT JOIN draft_options AS dopt
    ON li.vendor_id        = dopt.vendor_id
   AND li.global_entity_id = dopt.global_entity_id
   AND li.item_name        = dopt.option_name
WHERE mp.live_item_name IS NULL
);


-- ================================================================
-- PART 2 — Option-level comparison (choice groups)
-- ================================================================
CREATE TEMP TABLE tmp_option_comparison AS (
WITH

menu_case_closed AS (
  SELECT
    c.global_entity_id,
    ARRAY_REVERSE(SPLIT(REGEXP_REPLACE(TRIM(c.backend_id__c), r"[^a-zA-Z0-9\s]+", "-"), "-"))[SAFE_OFFSET(0)] AS vendor_id,
    MIN(c.closeddate) AS menu_submitted_at
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.case` AS c
  WHERE c.type = 'Menu Processing' AND c.status = 'Closed'
    AND DATE(c.closeddate) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH), MONTH)
    AND ARRAY_REVERSE(SPLIT(REGEXP_REPLACE(TRIM(c.backend_id__c), r"[^a-zA-Z0-9\s]+", "-"), "-"))[SAFE_OFFSET(0)] = "wu5t"
  GROUP BY 1, 2
),

sf_activation AS (
  SELECT a.global_entity_id, a.grid__c AS grid, MIN(ah.createddate) AS sf_active_at
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.account_history` AS ah
    JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.account` AS a
      ON ah.accountid = a.id AND ah.global_entity_id = a.global_entity_id
  WHERE ah.field = 'Account_Status__c' AND ah.newvalue = 'Active'
    AND a.global_entity_id = "FP_PH" AND a.grid__c = "HTA5NP"
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
  WHERE dm.vendor_id = "wu5t"
    AND CHAR_LENGTH(item.name) > 0
    AND JSON_VALUE(sel, '$.selection_name') IS NOT NULL
),

live_options AS (
  SELECT DISTINCT
    ps.content.vendor.vendor_id       AS vendor_id,
    ps.global_entity_id,
    REPLACE(attr.name, 'Choice_', '')  AS live_choice_group_name,
    LOWER(TRIM(ps.content.name))       AS option_name
  FROM `fulfillment-dwh-production.curated_data_shared_data_stream.product_stream` AS ps
    JOIN sf_activation AS sfa ON sfa.global_entity_id = ps.global_entity_id
    LEFT JOIN scc_completion AS scc
      ON scc.vendor_id = ps.content.vendor.vendor_id AND scc.global_entity_id = ps.global_entity_id
    LEFT JOIN menu_case_closed AS mcc
      ON mcc.vendor_id = ps.content.vendor.vendor_id AND mcc.global_entity_id = ps.global_entity_id
    , UNNEST(ps.content.attributes) AS attr
  WHERE ps.global_entity_id = "FP_PH"
    AND ps.content.vendor.vendor_id = "wu5t"
    AND ps.created_date >= DATE_SUB(CURRENT_DATE, INTERVAL 2 MONTH)
    AND ps.timestamp BETWEEN
          COALESCE(TIMESTAMP(scc.catalog_created_at), TIMESTAMP(mcc.menu_submitted_at))
          AND TIMESTAMP(sfa.sf_active_at)
    AND NOT COALESCE(ps.content.deleted, FALSE)
    AND STARTS_WITH(attr.name, 'Choice_')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ps.content.vendor.vendor_id, ps.global_entity_id, LOWER(TRIM(ps.content.name)), attr.name
    ORDER BY ps.content.timestamp
  ) = 1
)

SELECT
  dopt.vendor_id, dopt.global_entity_id,
  dopt.parent_item_name,
  dopt.option_group                                                          AS draft_option_group,
  COUNT(DISTINCT dopt.option_name)                                           AS draft_option_count,
  COUNT(DISTINCT lo.option_name)                                             AS live_option_count,
  COUNT(DISTINCT dopt.option_name) - COUNT(DISTINCT lo.option_name)         AS missing_from_live,
  ARRAY_AGG(DISTINCT dopt.option_name ORDER BY dopt.option_name)            AS draft_options,
  ARRAY_AGG(DISTINCT lo.option_name IGNORE NULLS ORDER BY lo.option_name)   AS live_options
FROM draft_options AS dopt
  LEFT JOIN live_options AS lo
    ON dopt.vendor_id        = lo.vendor_id
   AND dopt.global_entity_id = lo.global_entity_id
   AND dopt.option_name      = lo.option_name
GROUP BY 1, 2, 3, 4
);


-- ================================================================
-- RESULT 1: Item-level detail
-- ================================================================
SELECT
  vendor_id, global_entity_id, match_status, draft_option_parent,
  draft_item_name, live_item_name, name_edit_dist_pct,
  draft_description, live_description, desc_overlap_pct
FROM tmp_item_comparison
ORDER BY
  CASE match_status
    WHEN 'matched_exact'               THEN 1
    WHEN 'matched_fuzzy'               THEN 2
    WHEN 'draft_only'                  THEN 3
    WHEN 'live_only_in_draft_as_option' THEN 4
    WHEN 'live_only'                   THEN 5
  END,
  COALESCE(draft_item_name, live_item_name);


-- ================================================================
-- RESULT 2: Option group accuracy (absolute counts per choice group)
-- ================================================================
SELECT
  vendor_id, global_entity_id, parent_item_name, draft_option_group,
  draft_option_count, live_option_count, missing_from_live,
  draft_option_count = live_option_count AS all_options_present,
  draft_options, live_options
FROM tmp_option_comparison
ORDER BY parent_item_name, draft_option_group;


-- ================================================================
-- RESULT 3: Vendor-level scores
--
-- TPC: matched items / total live items
--      "What % of the live menu did the draft correctly anticipate?"
--
-- DA:  avg clean word-overlap for matched items
--      "For items it identified, how accurate were the descriptions?"
--
-- CA:  draft options present in live / total draft options
--      "What % of choice options survived to the live menu?"
--
-- Composite = equal 1/3 each (adjust multipliers below to rebalance)
--
-- To aggregate across vendors: weight each row by total_live_items
-- e.g. SUM(tpc * total_live_items) / SUM(total_live_items)
-- ================================================================
WITH
item_scores AS (
  SELECT
    vendor_id, global_entity_id,
    COUNT(DISTINCT live_item_name)                                                                            AS total_live_items,
    COUNT(DISTINCT draft_item_name)                                                                           AS total_draft_items,
    COUNTIF(match_status IN ('matched_exact', 'matched_fuzzy'))                                               AS matched_items,
    ROUND(AVG(IF(match_status IN ('matched_exact', 'matched_fuzzy') AND desc_overlap_pct IS NOT NULL,
                 desc_overlap_pct, NULL)), 1)                                                                 AS description_accuracy_pct
  FROM tmp_item_comparison
  GROUP BY 1, 2
),
option_scores AS (
  SELECT
    vendor_id, global_entity_id,
    SUM(draft_option_count) AS total_draft_options,
    SUM(live_option_count)  AS total_live_options_matched
  FROM tmp_option_comparison
  GROUP BY 1, 2
)
SELECT
  i.vendor_id,
  i.global_entity_id,

  -- Raw counts (use these for cross-vendor weighted aggregation)
  i.total_draft_items,
  i.total_live_items,
  i.matched_items,
  o.total_draft_options,
  o.total_live_options_matched,

  -- Score 1: Total Product Completeness
  ROUND(100.0 * i.matched_items / NULLIF(i.total_live_items, 0), 1)                              AS total_product_completeness_pct,

  -- Score 2: Description Accuracy
  i.description_accuracy_pct,

  -- Score 3: Choice Accuracy
  ROUND(100.0 * o.total_live_options_matched / NULLIF(o.total_draft_options, 0), 1)              AS choice_accuracy_pct,

  -- Composite (equal weights — adjust the /3.0 denominator and coefficients to rebalance)
  ROUND((
      COALESCE(ROUND(100.0 * i.matched_items / NULLIF(i.total_live_items, 0), 1), 0)
    + COALESCE(i.description_accuracy_pct, 0)
    + COALESCE(ROUND(100.0 * o.total_live_options_matched / NULLIF(o.total_draft_options, 0), 1), 0)
  ) / 3.0, 1)                                                                                     AS composite_score

FROM item_scores   AS i
  LEFT JOIN option_scores AS o USING (vendor_id, global_entity_id);
