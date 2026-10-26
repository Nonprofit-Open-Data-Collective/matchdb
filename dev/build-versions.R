# The source versions that define a build. dev/build-matchdb.R and
# dev/build-ledger.R both read this file, so a version is changed in one place.

V <- list(
  bmf_unified       = "v2026-09-21",   # nccsdata geocoding/unified-bmf/latest, 2026-09-21
  ntee_crosswalk    = "v2026-09",      # nccsdata crosswalks/ntee-resolved, 2026-09-21
  f1023ez           = "v2014-2023",    # irs.gov irs-tege, all ten published years
  efile             = "v3_1",          # NCCS e-file v3_1, tax years 2009-2025
  address_crosswalk = "v2026-07",      # nccsdata crosswalks/address-resolved/v2026_07
  address_geocoded  = "v2024-05",      # nccsdata meta/metadata-address-geocoded.csv
  meta_group_number = "v2023-09",      # nccsdata meta/metadata-group-number.csv
  irs527_related    = "v2024-11-15",   # nccsdata public/pacs/2024-11-POL-ORGS-SCHED-R.csv
  e_postcard        = "v2026-07",      # nccsdata raw/e-postcard/2026-07-E-POSTCARD.csv
  revocations       = "v2026-07"       # nccsdata raw/revocations/2026-07-REVOCATIONS-ORGS.csv
)
EFILE_SOURCES <- c("efile_header", "schedi", "efile_related", "efile_disregarded", "efile_officers",
                   "efile_related_ptr", "efile_related_corp", "efile_orgtext",
                   "efile_affiliate_listing", "efile_sched_c_affil")
