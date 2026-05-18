-- ============================================================
-- Stage:   MDS NOT RECEIVED
-- Region:  HungerStation | Non SSU | Seamless Market | 2026-04
-- Changes: #7 (SSU misclassification), #8 (success outside 744h window),
--          #9 (DLQ record in wrong bucket), #10 (no file URL bug ticket)
-- ============================================================

-- STEP 1: Entity breakdown of the 69 vendors
SELECT
  global_entity_id,
  COUNT(DISTINCT vendor_id) AS vendor_count
FROM `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel`
WHERE management_entity          = 'HungerStation'
  AND account_source_curated     = 'Non SSU'
  AND onboard_month              = '2026-04-01'
  AND is_seamless_market         = TRUE
  AND is_funnel_mds_not_received = TRUE
GROUP BY 1
ORDER BY 2 DESC;


-- ============================================================
-- STEP 2: Full comparison — SF account + SF case + MDS success + MDS DLQ
-- ============================================================
WITH

mds_not_received AS (
  SELECT
    management_entity,
    global_entity_id,
    grid_id,
    vendor_id,
    onboarded_date,
    account_source_curated        AS fact_account_source_curated,
    business_type,
    has_menu_file
  FROM `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel`
  WHERE management_entity          = 'HungerStation'
    AND account_source_curated     = 'Non SSU'
    AND onboard_month              = '2026-04-01'
    AND is_seamless_market         = TRUE
    AND is_funnel_mds_not_received = TRUE
),

mds_success AS (
  SELECT
    vendor_id,
    global_entity_id,
    submission_id,
    submission_timestamp,
    status_code                   AS mds_status_code
  FROM `dh-global-sales-data.raw_vendor.mds_digitalised_menu_prod`
  WHERE attributes.system IN ('salesforce_acquisition', 'sf_menu_onboarding')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY vendor_id, global_entity_id
    ORDER BY submission_timestamp DESC
  ) = 1
),

mds_dlq AS (
  SELECT
    vendor_id,
    global_entity_id,
    submission_id,
    submission_timestamp,
    status_code                   AS dlq_status_code,
    (SELECT cd.value FROM UNNEST(custom_data) AS cd WHERE cd.key = 'message'  LIMIT 1) AS dlq_error_message,
    (SELECT cd.value FROM UNNEST(custom_data) AS cd WHERE cd.key = 'grid'     LIMIT 1) AS dlq_grid,
    (SELECT cd.value FROM UNNEST(custom_data) AS cd WHERE cd.key = 'file_id'  LIMIT 1) AS dlq_file_id
  FROM `dh-global-sales-data.raw_vendor.mds_dead_letter_prod`
  WHERE attributes.system IN ('salesforce_acquisition', 'sf_menu_onboarding')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY vendor_id, global_entity_id
    ORDER BY submission_timestamp DESC
  ) = 1
),

sf_menu_case AS (
  SELECT
    grid__c,
    global_entity_id,
    status                        AS sf_case_status,
    closed_reason__c              AS sf_case_closed_reason,
    origin                        AS sf_case_origin,
    draft_menu_stage__c           AS sf_draft_menu_stage,
    automation_status__c          AS sf_automation_status,
    menu_url__c                   AS sf_menu_url,
    createddate                   AS sf_case_created_date,
    closeddate                    AS sf_case_closed_date
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.case`
  WHERE type = 'Menu Processing'
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY grid__c, global_entity_id
    ORDER BY createddate DESC
  ) = 1
)

SELECT
  f.management_entity,
  f.global_entity_id,
  f.grid_id,
  f.vendor_id,
  f.onboarded_date,
  f.fact_account_source_curated,
  f.business_type,

  sf_acct.accountsource           AS sf_accountsource,
  CASE
    WHEN sf_acct.accountsource = 'Self Sign Up' AND f.fact_account_source_curated = 'Non SSU'
      THEN 'MISMATCH: SF=SSU, Fact=Non SSU'
    ELSE 'OK'
  END                             AS account_source_check,

  sf_case.sf_case_status,
  sf_case.sf_case_closed_reason,
  sf_case.sf_case_origin,
  sf_case.sf_draft_menu_stage,
  sf_case.sf_automation_status,
  sf_case.sf_menu_url,
  sf_case.sf_case_created_date,
  sf_case.sf_case_closed_date,

  mds_s.submission_id             AS mds_success_submission_id,
  mds_s.submission_timestamp      AS mds_success_timestamp,
  mds_s.mds_status_code           AS mds_success_status_code,

  mds_d.submission_id             AS mds_dlq_submission_id,
  mds_d.submission_timestamp      AS mds_dlq_timestamp,
  mds_d.dlq_status_code,
  mds_d.dlq_error_message,
  mds_d.dlq_file_id,

  CASE
    WHEN sf_acct.accountsource = 'Self Sign Up'
      THEN 'EXCLUDE: SSU vendor in Non SSU filter'
    WHEN mds_s.submission_id IS NOT NULL
      THEN 'CHECK: MDS success record exists outside 744h window'
    WHEN mds_d.submission_id IS NOT NULL
      THEN CONCAT('MDS FAILED: ', COALESCE(mds_d.dlq_error_message, 'No message'), ' (code: ', CAST(mds_d.dlq_status_code AS STRING), ')')
    WHEN sf_case.sf_menu_url IS NULL
      THEN 'NO FILE URL: Menu case closed but no file URL on SF case'
    ELSE 'TRUE MDS NOT RECEIVED: File present, case closed, no MDS record'
  END                             AS diagnosis

FROM mds_not_received AS f
LEFT JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.account` AS sf_acct
  ON  f.grid_id          = sf_acct.grid__c
  AND f.global_entity_id = sf_acct.global_entity_id
LEFT JOIN sf_menu_case AS sf_case
  ON  f.grid_id          = sf_case.grid__c
  AND f.global_entity_id = sf_case.global_entity_id
LEFT JOIN mds_success AS mds_s
  ON  f.vendor_id        = mds_s.vendor_id
  AND f.global_entity_id = mds_s.global_entity_id
LEFT JOIN mds_dlq AS mds_d
  ON  f.vendor_id        = mds_d.vendor_id
  AND f.global_entity_id = mds_d.global_entity_id

ORDER BY diagnosis, f.global_entity_id, f.onboarded_date;


-- ============================================================
-- STEP 3: Diagnosis summary count
-- ============================================================
WITH
mds_not_received AS (
  SELECT management_entity, global_entity_id, grid_id, vendor_id, onboarded_date,
    account_source_curated AS fact_account_source_curated, business_type, has_menu_file
  FROM `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel`
  WHERE management_entity = 'HungerStation' AND account_source_curated = 'Non SSU'
    AND onboard_month = '2026-04-01' AND is_seamless_market = TRUE
    AND is_funnel_mds_not_received = TRUE
),
mds_success AS (
  SELECT vendor_id, global_entity_id, submission_id
  FROM `dh-global-sales-data.raw_vendor.mds_digitalised_menu_prod`
  WHERE attributes.system IN ('salesforce_acquisition', 'sf_menu_onboarding')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY vendor_id, global_entity_id ORDER BY submission_timestamp DESC) = 1
),
mds_dlq AS (
  SELECT vendor_id, global_entity_id, submission_id
  FROM `dh-global-sales-data.raw_vendor.mds_dead_letter_prod`
  WHERE attributes.system IN ('salesforce_acquisition', 'sf_menu_onboarding')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY vendor_id, global_entity_id ORDER BY submission_timestamp DESC) = 1
),
sf_menu_case AS (
  SELECT grid__c, global_entity_id, menu_url__c
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.case`
  WHERE type = 'Menu Processing'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY grid__c, global_entity_id ORDER BY createddate DESC) = 1
)
SELECT
  CASE
    WHEN sf_acct.accountsource = 'Self Sign Up' THEN 'EXCLUDE: SSU vendor in Non SSU filter'
    WHEN mds_s.submission_id   IS NOT NULL       THEN 'CHECK: MDS success exists outside 744h window'
    WHEN mds_d.submission_id   IS NOT NULL       THEN 'MDS FAILED: Record in DLQ'
    WHEN sf_case.menu_url__c   IS NULL           THEN 'NO FILE URL: File not transmitted to MDS'
    ELSE                                              'TRUE MDS NOT RECEIVED: File present, no MDS record'
  END AS diagnosis,
  COUNT(*) AS vendor_count
FROM mds_not_received AS f
LEFT JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.account` AS sf_acct
  ON f.grid_id = sf_acct.grid__c AND f.global_entity_id = sf_acct.global_entity_id
LEFT JOIN sf_menu_case AS sf_case
  ON f.grid_id = sf_case.grid__c AND f.global_entity_id = sf_case.global_entity_id
LEFT JOIN mds_success AS mds_s
  ON f.vendor_id = mds_s.vendor_id AND f.global_entity_id = mds_s.global_entity_id
LEFT JOIN mds_dlq AS mds_d
  ON f.vendor_id = mds_d.vendor_id AND f.global_entity_id = mds_d.global_entity_id
GROUP BY 1
ORDER BY 2 DESC;


-- ============================================================
-- STEP 4: Extract NO FILE URL vendors for bug ticket (Change #10)
-- ============================================================
WITH
mds_not_received AS (
  SELECT management_entity, global_entity_id, grid_id, vendor_id, onboarded_date,
    account_source_curated AS fact_account_source_curated, business_type, has_menu_file
  FROM `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel`
  WHERE management_entity = 'HungerStation' AND account_source_curated = 'Non SSU'
    AND onboard_month = '2026-04-01' AND is_seamless_market = TRUE
    AND is_funnel_mds_not_received = TRUE
),
mds_success AS (
  SELECT vendor_id, global_entity_id, submission_id
  FROM `dh-global-sales-data.raw_vendor.mds_digitalised_menu_prod`
  WHERE attributes.system IN ('salesforce_acquisition', 'sf_menu_onboarding')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY vendor_id, global_entity_id ORDER BY submission_timestamp DESC) = 1
),
mds_dlq AS (
  SELECT vendor_id, global_entity_id, submission_id
  FROM `dh-global-sales-data.raw_vendor.mds_dead_letter_prod`
  WHERE attributes.system IN ('salesforce_acquisition', 'sf_menu_onboarding')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY vendor_id, global_entity_id ORDER BY submission_timestamp DESC) = 1
),
sf_menu_case AS (
  SELECT grid__c, global_entity_id, status AS sf_case_status, closed_reason__c AS sf_case_closed_reason,
    menu_url__c AS sf_menu_url, createddate AS sf_case_created_date, closeddate AS sf_case_closed_date
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.case`
  WHERE type = 'Menu Processing'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY grid__c, global_entity_id ORDER BY createddate DESC) = 1
)
SELECT
  f.management_entity,
  f.global_entity_id,
  f.grid_id,
  f.vendor_id,
  CAST(f.onboarded_date AS STRING)             AS onboarded_date,
  f.fact_account_source_curated,
  f.business_type,
  sf_acct.accountsource                        AS sf_accountsource,
  sf_case.sf_case_status,
  sf_case.sf_case_closed_reason,
  sf_case.sf_menu_url,
  CAST(sf_case.sf_case_created_date AS STRING) AS sf_case_created_date,
  CAST(sf_case.sf_case_closed_date AS STRING)  AS sf_case_closed_date,
  'NO FILE URL: File likely not transmitted to MDS — no processing or failure record exists' AS issue_description,
  'Raise bug ticket to tech: menu file URL missing on closed Menu Processing case — MDS never received file' AS recommended_action
FROM mds_not_received AS f
LEFT JOIN `fulfillment-dwh-production.curated_data_shared_salesforce.account` AS sf_acct
  ON f.grid_id = sf_acct.grid__c AND f.global_entity_id = sf_acct.global_entity_id
LEFT JOIN sf_menu_case AS sf_case
  ON f.grid_id = sf_case.grid__c AND f.global_entity_id = sf_case.global_entity_id
LEFT JOIN mds_success AS mds_s
  ON f.vendor_id = mds_s.vendor_id AND f.global_entity_id = mds_s.global_entity_id
LEFT JOIN mds_dlq AS mds_d
  ON f.vendor_id = mds_d.vendor_id AND f.global_entity_id = mds_d.global_entity_id
WHERE sf_acct.accountsource != 'Self Sign Up'
  AND mds_s.submission_id IS NULL
  AND mds_d.submission_id IS NULL
  AND sf_case.sf_menu_url IS NULL
ORDER BY f.global_entity_id, f.onboarded_date;
