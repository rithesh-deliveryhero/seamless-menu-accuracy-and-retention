-- ================================================================
-- POPULATION: FP_PH | Non SSU | Seamless Market | April 2026
-- 559 vendors that reached DRAFTS CREATED
--   (360 Drafts Not Retained + 199 Retained in SF)
--
-- Flags shared/mirrored menu cases by reading the
-- Onboarding_Menu_Comments__c field on each vendor's
-- Menu Processing case.
--
-- Two flag columns:
--   has_shared_menu_keyword    — phrase matched (may include false positives)
--   is_confirmed_shared_menu   — phrase matched AND source vendor ID resolves
--                                to a real FP_PH vendor in the vendors table
-- ================================================================

WITH

population AS (
  SELECT
    global_entity_id,
    grid_id,
    vendor_id,
    onboarded_date,
    onboard_month,
    account_source_curated,
    business_type,
    management_entity,
    CASE
      WHEN is_funnel_drafts_not_retained = TRUE THEN 'Drafts Not Retained'
      WHEN is_funnel_retained_in_sf      = TRUE THEN 'Retained in SF'
    END AS draft_outcome
  FROM `fulfillment-dwh-production.curated_data_shared_vendor.fact_vso_vrm_mds_menu_funnel`
  WHERE global_entity_id       = 'FP_PH'
    AND onboard_month          = '2026-04-01'
    AND account_source_curated = 'Non SSU'
    AND is_seamless_market     = TRUE
    AND (
      is_funnel_drafts_not_retained = TRUE
      OR is_funnel_retained_in_sf   = TRUE
    )
),

menu_cases AS (
  -- Latest Menu Processing case per grid; extract source vendor ID from comment
  SELECT
    c.grid__c,
    c.global_entity_id,
    c.casenumber,
    c.onboarding_menu_comments__c AS raw_comment,
    -- Cascade of patterns, most specific first. COALESCE returns the first non-null match.
    --
    -- Pattern 1 (original): sync from / mirror / same as / copy menu of / same menu with / sync
    -- Pattern 2 (new): "same with: HKFHEZ"  — grid written after "same with:"
    -- Pattern 3 (new): vendor/grid in parentheses e.g. "BKSHP ONLY (t4i3)"
    -- Pattern 4 (new): "sync to this grid - HREJHZ"
    COALESCE(
      REGEXP_EXTRACT(
        LOWER(c.onboarding_menu_comments__c),
        r'(?:sync from|mirror|copy menu of:?\s*|same menu with(?:\s+vendor code)?\s*|same as|sync)\s*\[?([a-z][a-z0-9-]{1,9})'
      ),
      REGEXP_EXTRACT(
        LOWER(c.onboarding_menu_comments__c),
        r'same with[:\s]+([a-z0-9]{4,6})'
      ),
      REGEXP_EXTRACT(
        LOWER(c.onboarding_menu_comments__c),
        r'\(([a-z][a-z0-9]{2,5})\)'
      ),
      REGEXP_EXTRACT(
        LOWER(c.onboarding_menu_comments__c),
        r'sync to this grid\s*[-]\s*([a-z0-9]{4,6})'
      )
    ) AS source_vendor_raw
  FROM `fulfillment-dwh-production.curated_data_shared_salesforce.case` AS c
  WHERE c.global_entity_id = 'FP_PH'
    AND c.type             = 'Menu Processing'
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY c.grid__c, c.global_entity_id
    ORDER BY c.createddate DESC
  ) = 1
)

SELECT
  p.global_entity_id,
  p.grid_id,
  p.vendor_id,
  p.onboarded_date,
  p.draft_outcome,
  p.business_type,
  p.account_source_curated,

  -- Case reference
  mc.casenumber,

  -- Raw text extracted by regex (for QA / manual review)
  mc.source_vendor_raw,

  -- How the source was resolved (vendor_id or grid_id lookup)
  CASE
    WHEN src_by_vid.vendor_id  IS NOT NULL THEN 'matched_as_vendor_id'
    WHEN src_by_grid.vendor_id IS NOT NULL THEN 'matched_as_grid_id'
    ELSE NULL
  END                                                        AS source_match_type,

  -- Resolved source identifiers (whichever lookup succeeded)
  COALESCE(src_by_vid.vendor_id,       src_by_grid.vendor_id)       AS source_vendor_id,
  COALESCE(src_by_vid.salesforce.grid, src_by_grid.salesforce.grid) AS source_grid_id,

  -- Flag 1: a sharing phrase was found in the comment (check source_vendor_raw to verify)
  mc.source_vendor_raw IS NOT NULL                                   AS has_shared_menu_keyword,

  -- Flag 2: phrase found AND source resolves via either vendor_id OR grid lookup
  mc.source_vendor_raw IS NOT NULL
    AND COALESCE(src_by_vid.vendor_id, src_by_grid.vendor_id) IS NOT NULL AS is_confirmed_shared_menu,

  -- Full comment (truncated — remove SUBSTR to see everything)
  SUBSTR(mc.raw_comment, 1, 500)                                     AS comment_preview

FROM population AS p
LEFT JOIN menu_cases AS mc
  ON p.grid_id          = mc.grid__c
 AND p.global_entity_id = mc.global_entity_id
-- Try lookup as vendor_id (e.g. "bcy5")
LEFT JOIN `fulfillment-dwh-production.curated_data_shared_coredata_business.vendors` AS src_by_vid
  ON src_by_vid.vendor_id        = REGEXP_REPLACE(mc.source_vendor_raw, r'^[a-z]{2,4}-', '')
 AND src_by_vid.global_entity_id = 'FP_PH'
-- Also try lookup as grid ID (e.g. comment says "HZ3IDM" → extracted as "hz3idm" → UPPER → "HZ3IDM")
LEFT JOIN `fulfillment-dwh-production.curated_data_shared_coredata_business.vendors` AS src_by_grid
  ON src_by_grid.salesforce.grid  = UPPER(REGEXP_REPLACE(mc.source_vendor_raw, r'^[a-z]{2,4}-', ''))
 AND src_by_grid.global_entity_id = 'FP_PH'

ORDER BY
  is_confirmed_shared_menu DESC,
  has_shared_menu_keyword  DESC,
  p.draft_outcome,
  p.vendor_id
