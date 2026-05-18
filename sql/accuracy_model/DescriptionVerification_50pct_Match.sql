-- ============================================================
-- PURPOSE: Manual verification of descriptions for 5 grids
--          with avg description word-overlap closest to 50%
--          (avg_desc_word_overlap ≈ 0.5 from final_metrics)
-- HOW TO USE:
--   1. Run as-is — picks the 5 grids nearest 50% desc overlap.
--   2. Flip the country filter ("FP_PH") and product_stream date
--      the same way you do in the source script.
-- ============================================================

WITH

onboarded_vendors_ssu AS (
  SELECT
    fvlagd.global_entity_id,
    fvlagd.grid_id,
    fvlagd.vendor_id,
    fvlagd.lead.lead_source_curated,
    fvlagd.account.account_source_curated,
    fvlagd.onboarding.onboarded_date,
    fvlagd.onboarding.onboarded_at,
    IF(fvlagd.onboarding.menu_closed_date IS NOT NULL, TRUE, FALSE) AS is_menu_submitted,
    IF(account.shared_menu__c IS NULL, FALSE, TRUE)                 AS has_shared_menu,
    account.vertical__c AS vertical,
    fvog.opportunity_business_type
  FROM `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_lead_account_gen_detail` AS fvlagd
    LEFT JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.account` AS account
           ON fvlagd.account.account_id = account.id
          AND fvlagd.global_entity_id   = account.global_entity_id
    LEFT JOIN `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_opportunity_gen` AS fvog
           ON fvlagd.account.account_id = fvog.account_id
          AND fvlagd.global_entity_id   = fvog.global_entity_id
  WHERE fvlagd.lead_created_date >= DATE_TRUNC(DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH), MONTH)
    AND fvlagd.onboarding.onboarded_date IS NOT NULL
    AND fvlagd.account.account_source_curated LIKE "%SSU%"
    AND fvog.opportunity_business_type IN ("New Business", "Win Back", "Franchise Extension")
),

menu_submission AS (
  SELECT
    sf_case.closeddate,
    sf_case.grid__c,
    sf_case.closed_reason__c,
    sf_case.global_entity_id,
    sf_case.status
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.case` AS sf_case
  WHERE sf_case.type = "Menu Processing"
    AND sf_case.status = "Closed"
    AND DATE(sf_case.closeddate) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH), MONTH)
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY sf_case.grid__c, sf_case.global_entity_id, DATE_TRUNC(sf_case.createddate, MONTH)
    ORDER BY sf_case.createddate
  ) = 1
),

onboarded_vendors_nssu AS (
  SELECT
    sf_case.status,
    sf_case.type,
    sf_case.closed_reason__c,
    sf_case.closeddate AS onboarded_timestamp,
    sf_case.grid__c    AS grid_id,
    vendors.vendor_id,
    sf_case.global_entity_id,
    account_gen.account_source_curated,
    IF(menu_submission.grid__c IS NOT NULL, TRUE, FALSE) AS is_menu_submitted,
    IF(account.shared_menu__c IS NULL, FALSE, TRUE)      AS has_shared_menu,
    account.vertical__c AS vertical,
    sf_opportunity.business_type__c
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.case` AS sf_case
    LEFT JOIN `fulfillment-dwh-production.curated_data_shared_coredata_business.vendors` AS vendors
           ON sf_case.grid__c          = vendors.salesforce.grid
          AND sf_case.global_entity_id = vendors.global_entity_id
    LEFT JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.account` AS account
           ON sf_case.accountid        = account.id
          AND sf_case.global_entity_id = account.global_entity_id
    LEFT JOIN `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_account_gen` AS account_gen
           ON sf_case.accountid        = account_gen.account_id
          AND sf_case.global_entity_id = account_gen.global_entity_id
    LEFT JOIN menu_submission
           ON sf_case.grid__c          = menu_submission.grid__c
          AND sf_case.global_entity_id = menu_submission.global_entity_id
          AND TIMESTAMP_DIFF(sf_case.closeddate, menu_submission.closeddate, HOUR) BETWEEN 0 AND 3000
    LEFT JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.opportunity` AS sf_opportunity
           ON sf_case.opportunity__c = sf_opportunity.id
  WHERE DATE(sf_case.closeddate) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH), MONTH)
    AND sf_case.status             = "Closed"
    AND sf_case.closed_reason__c   = "Successful"
    AND sf_case.type               = "Onboarding"
    AND account_gen.account_source_curated NOT LIKE "%SSU%"
    AND sf_opportunity.business_type__c IN ("New Business", "Win Back", "Franchise Extension")
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY sf_case.grid__c, sf_case.global_entity_id, DATE_TRUNC(sf_case.closeddate, MONTH)
    ORDER BY sf_case.closeddate DESC
  ) = 1
),

onboarded_vendors AS (
  SELECT
    global_entity_id, grid_id, vendor_id, account_source_curated,
    DATE(onboarded_date) AS onboarded_date, onboarded_at,
    is_menu_submitted, has_shared_menu, vertical,
    opportunity_business_type AS business_type
  FROM onboarded_vendors_ssu
  WHERE vertical = "Restaurant"

  UNION ALL

  SELECT
    global_entity_id, grid_id, vendor_id, account_source_curated,
    DATE(onboarded_timestamp) AS onboarded_date, onboarded_timestamp AS onboarded_at,
    is_menu_submitted, has_shared_menu, vertical,
    business_type__c AS business_type
  FROM onboarded_vendors_nssu
  WHERE vertical = "Restaurant"
),

menu_case_closed AS (
  SELECT
    c.global_entity_id,
    ARRAY_REVERSE(SPLIT(REGEXP_REPLACE(TRIM(c.backend_id__c), r"[^a-zA-Z0-9\s]+", "-"), "-"))[SAFE_OFFSET(0)] AS vendor_id,
    MIN(c.closeddate) AS menu_submitted_at
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.case` AS c
  WHERE c.type = 'Menu Processing'
    AND c.status = 'Closed'
    AND DATE(c.closeddate) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE, INTERVAL 12 MONTH), MONTH)
  GROUP BY 1, 2
),

sf_activation AS (
  SELECT
    a.global_entity_id,
    a.grid__c AS grid,
    MIN(ah.createddate) AS sf_active_at
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.account_history` AS ah
    JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.account` AS a
      ON ah.accountid = a.id AND ah.global_entity_id = a.global_entity_id
  WHERE ah.field = 'Account_Status__c'
    AND ah.newvalue = 'Active'
    AND DATE(ah.createddate) >= DATE_TRUNC(DATE_SUB(CURRENT_DATE, INTERVAL 13 MONTH), MONTH)
  GROUP BY 1, 2
),

draft_menu_items AS (
  SELECT DISTINCT
    dm.vendor_id, dm.global_entity_id,
    LOWER(TRIM(item.name))        AS item_name,
    LOWER(TRIM(item.description)) AS item_description
  FROM `dh-central-salesforce-tech.dh_salesforce_scc_draft_menu.dh_salesforce_draft_menu` AS dm
    , UNNEST(dm.items) AS item
  WHERE CHAR_LENGTH(item.name) > 0
),

scc_completion AS (
  SELECT job.vendor_id, job.global_entity_id, MIN(job.timestamp) AS catalog_created_at
  FROM `dh-central-salesforce-tech.dh_salesforce_scc_draft_menu.dh_salesforce_scc_job_info` AS job
    JOIN menu_case_closed AS mcc
      ON job.vendor_id = mcc.vendor_id AND job.global_entity_id = mcc.global_entity_id
  WHERE job.status = 'Completed'
    AND job.type = 'gms-products'
    AND TIMESTAMP_DIFF(job.timestamp, mcc.menu_submitted_at, HOUR) BETWEEN -168 AND 744
  GROUP BY 1, 2
),

live_menu AS (
  SELECT DISTINCT
    ov.vendor_id,
    ov.global_entity_id,
    ov.onboarded_date,
    LOWER(TRIM(ps.content.name))        AS item_name,
    LOWER(TRIM(ps.content.description)) AS live_desc
  FROM onboarded_vendors AS ov
    JOIN sf_activation AS sfa
      ON ov.grid_id = sfa.grid AND ov.global_entity_id = sfa.global_entity_id
    LEFT JOIN scc_completion AS scc
      ON ov.vendor_id = scc.vendor_id AND ov.global_entity_id = scc.global_entity_id
    LEFT JOIN menu_case_closed AS mcc
      ON ov.vendor_id = mcc.vendor_id AND ov.global_entity_id = mcc.global_entity_id
    JOIN `fulfillment-dwh-production.curated_data_shared_data_stream.product_stream` AS ps
      ON ps.global_entity_id         = ov.global_entity_id
     AND ps.content.vendor.vendor_id = ov.vendor_id
     AND ps.timestamp BETWEEN
           COALESCE(TIMESTAMP(scc.catalog_created_at), TIMESTAMP(mcc.menu_submitted_at))
           AND TIMESTAMP(sfa.sf_active_at)
     AND ps.created_date >= DATE_SUB(CURRENT_DATE, INTERVAL 2 MONTH) -- change product stream date here
  WHERE NOT COALESCE(ps.content.deleted, FALSE)
    AND NOT EXISTS (
      SELECT 1 FROM UNNEST(ps.content.attributes) AS attr
      WHERE attr.name = '_Choices'
    )
    AND ov.global_entity_id = "FP_PH" -- change country here
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY ov.vendor_id, ov.global_entity_id, LOWER(TRIM(ps.content.name))
    ORDER BY ps.content.timestamp
  ) = 1
),

item_similarity AS (
  SELECT DISTINCT
    di.vendor_id,
    di.global_entity_id,
    li.onboarded_date,
    di.item_name,
    di.item_description,
    li.live_desc,
    li.item_name IS NOT NULL AS is_matched,
    SAFE_DIVIDE(
      (SELECT COUNT(1) FROM UNNEST(SPLIT(COALESCE(di.item_description, ""), " ")) AS w
       WHERE w IN UNNEST(SPLIT(COALESCE(li.live_desc, ""), " ")) AND w != ""),
      NULLIF(ARRAY_LENGTH(SPLIT(COALESCE(di.item_description, ""), " ")), 0)
    ) AS word_overlap_score
  FROM draft_menu_items AS di
    LEFT JOIN live_menu AS li
      ON di.vendor_id        = li.vendor_id
     AND di.global_entity_id = li.global_entity_id
     AND di.item_name        = li.item_name
),

final_metrics AS (
  SELECT
    vendor_id,
    global_entity_id,
    onboarded_date,
    COUNT(DISTINCT item_name)                                                     AS total_draft_items,
    COUNT(DISTINCT IF(is_matched, item_name, NULL))                               AS matched_items,
    ROUND(AVG(IF(is_matched, word_overlap_score, NULL)), 2)                       AS avg_desc_word_overlap,
    COUNT(DISTINCT IF(is_matched AND word_overlap_score >= 0.8, item_name, NULL)) AS desc_mostly_unchanged
  FROM item_similarity
  GROUP BY vendor_id, global_entity_id, onboarded_date
),

-- Pick 5 grids whose avg description word-overlap is closest to 50%
target_vendors AS (
  SELECT
    fm.vendor_id,
    fm.global_entity_id,
    fm.onboarded_date,
    fm.total_draft_items,
    fm.matched_items,
    ROUND(fm.matched_items / NULLIF(fm.total_draft_items, 0) * 100, 1) AS match_pct,
    fm.avg_desc_word_overlap,
    ABS(fm.avg_desc_word_overlap - 0.5)                                AS distance_from_50pct
  FROM final_metrics AS fm
    INNER JOIN `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel` AS f
      ON fm.vendor_id        = f.vendor_id
     AND fm.global_entity_id = f.global_entity_id
  WHERE f.is_funnel_drafts_not_retained = TRUE
    AND fm.global_entity_id = "FP_PH"
    AND fm.onboarded_date   IS NOT NULL
    AND fm.avg_desc_word_overlap IS NOT NULL   -- exclude vendors with no matched items
  ORDER BY distance_from_50pct
  LIMIT 5
)

-- Final: every item for those 5 grids, with both descriptions side by side
SELECT
  tv.vendor_id,
  tv.global_entity_id,
  tv.onboarded_date,
  tv.total_draft_items,
  tv.matched_items,
  tv.match_pct,
  ROUND(tv.avg_desc_word_overlap * 100, 1)           AS avg_desc_overlap_pct,

  itmsi.item_name,
  itmsi.item_description                                AS draft_description,
  itmsi.live_desc                                       AS live_description,
  itmsi.is_matched                                      AS item_name_matched,
  ROUND(COALESCE(itmsi.word_overlap_score, 0) * 100, 1) AS item_desc_overlap_pct

FROM target_vendors AS tv
  JOIN item_similarity AS itmsi
    ON tv.vendor_id        = itmsi.vendor_id
   AND tv.global_entity_id = itmsi.global_entity_id

ORDER BY
  tv.avg_desc_word_overlap,
  tv.vendor_id,
  itmsi.is_matched DESC,
  itmsi.item_name
