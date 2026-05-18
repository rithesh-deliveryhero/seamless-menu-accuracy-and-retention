-- ============================================================
-- Stage:   MENU FILE NOT PRESENT (NB)
-- Region:  Talabat | Non SSU | 2026-04
-- Changes: #1 (SSU misclassification), #2 (mandatory file enforcement)
-- ============================================================

-- STEP 1: Pull all 146 vendors in this bucket from the fact table
SELECT
  management_entity,
  global_entity_id,
  grid_id,
  vendor_id,
  onboarded_date,
  account_source_curated        AS fact_account_source_curated,
  business_type,
  has_menu_file,
  has_shared_menu,
  is_menu_submitted,
  is_success_mds_processed,
  is_errored_mds_processed,
  is_excluded_from_main_funnel,
  is_funnel_menu_file_not_present_nb
FROM `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel`
WHERE management_entity                    = 'Talabat'
  AND account_source_curated               = 'Non SSU'
  AND onboard_month                        = '2026-04-01'
  AND is_funnel_menu_file_not_present_nb   = TRUE
ORDER BY global_entity_id, onboarded_date;


-- ============================================================
-- STEP 2: SSU vs Non SSU comparison — Change #1
-- Joins SF account table to verify account_source_curated
-- ============================================================
SELECT
  f.management_entity,
  f.global_entity_id,
  f.grid_id,
  f.vendor_id,
  f.onboarded_date,

  -- Fact table classification
  f.account_source_curated              AS fact_account_source_curated,

  -- Raw Salesforce account source
  sf.accountsource                      AS sf_accountsource,

  -- Comparison
  CASE
    WHEN sf.accountsource = 'Self Sign Up' AND f.account_source_curated = 'Non SSU'
      THEN 'MISMATCH: SF=SSU, Fact=Non SSU'
    WHEN sf.accountsource != 'Self Sign Up' AND f.account_source_curated = 'SSU'
      THEN 'MISMATCH: SF=Non SSU, Fact=SSU'
    WHEN sf.accountsource IS NULL
      THEN 'WARNING: No SF account found'
    ELSE 'OK'
  END AS source_check

FROM `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel` AS f
LEFT JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.account` AS sf
  ON  f.grid_id          = sf.grid__c
  AND f.global_entity_id = sf.global_entity_id

WHERE f.management_entity                  = 'Talabat'
  AND f.account_source_curated             = 'Non SSU'
  AND f.onboard_month                      = '2026-04-01'
  AND f.is_funnel_menu_file_not_present_nb = TRUE

ORDER BY source_check, f.global_entity_id, f.onboarded_date;


-- ============================================================
-- STEP 3: Summary count by diagnosis
-- ============================================================
SELECT
  CASE
    WHEN sf.accountsource = 'Self Sign Up' AND f.account_source_curated = 'Non SSU'
      THEN 'MISMATCH: SF=SSU, Fact=Non SSU'
    WHEN sf.accountsource != 'Self Sign Up' AND f.account_source_curated = 'SSU'
      THEN 'MISMATCH: SF=Non SSU, Fact=SSU'
    WHEN sf.accountsource IS NULL
      THEN 'WARNING: No SF account found'
    ELSE 'OK'
  END AS source_check,
  COUNT(*) AS vendor_count

FROM `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel` AS f
LEFT JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.account` AS sf
  ON  f.grid_id          = sf.grid__c
  AND f.global_entity_id = sf.global_entity_id

WHERE f.management_entity                  = 'Talabat'
  AND f.account_source_curated             = 'Non SSU'
  AND f.onboard_month                      = '2026-04-01'
  AND f.is_funnel_menu_file_not_present_nb = TRUE

GROUP BY 1
ORDER BY 2 DESC;
