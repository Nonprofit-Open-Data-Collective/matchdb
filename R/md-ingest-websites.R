#' Ingest organisation websites
#'
#' Builds the `website` table from every source that carries a website field:
#' the 990 filing header (`F9_00_ORG_WEBSITE`), the 1023-EZ approvals
#' (`Orgurl`) and the 990-N e-Postcard (`website`). One row per
#' `(ein, site_key, source)`. Rebuilt whole on each call, like the derived
#' tables, because three sources feed it and `n_eins_sharing` spans all three.
#'
#' A website is strong evidence when it is specific to one organisation and
#' worthless when it is not, so the table records which is which rather than
#' leaving it to every consumer.
#'
#' @section What counts as a website:
#' The fields are free text, and much of it is not a website: `N/A`, `NONE`,
#' `TBD`, `SEE SCHEDULE O`, `UNDER CONSTRUCTION`, an organisation's name, even
#' `xxx-xx-xxxx`. Rather than list placeholders, a value is kept only if, after
#' cleaning, its host is a valid domain name: dot-separated labels of letters,
#' digits and hyphens ending in a 2-24 letter top-level domain. Cleaning
#' lowercases, turns a comma into a dot (`www,ptk.org` is a common typo), and
#' strips the scheme, a leading `www.` and any port. A value with spaces in its
#' host is not a website.
#'
#' An email address (`info@example.org`) is kept by its domain, as `kind =
#' 'email'`, because an organisation's mail domain is usually its web domain.
#' Mail from a personal provider (gmail.com, yahoo.com, ...) is dropped: it says
#' nothing about which organisation sent it.
#'
#' @section `site_key`: what a match would compare:
#' For most sites `site_key` is the host without `www.`. For pages hosted on a
#' shared platform (facebook.com, sites.google.com, a `*.wixsite.com` page,
#' linktr.ee, ...) the host identifies the platform, not the organisation, so
#' the key is the host plus the first path segment (`facebook.com/hullscove`),
#' and `is_platform` is `TRUE`. A bare platform host with no path is dropped.
#'
#' `n_eins_sharing` counts the EINs holding each `site_key`, across all sources.
#' A national body's site written by thousands of chapters (`elks.org`) is
#' family evidence, not identity evidence - the same distinction `name_compact`
#' draws with its own `n_eins_sharing`.
#'
#' @section Only known entities:
#' A website needs an entity to belong to. Rows for EINs absent from `entity`
#' are held back and counted, not admitted: the e-Postcard has 73,503 such EINs,
#' and whether to admit them is a decision for an e-Postcard entity ingest, not
#' for this one.
#'
#' @param con A connection from [md_db()].
#' @param efile_version Pinned `efile_header` version, or `NULL` to skip.
#' @param f1023ez_version Pinned `f1023ez` version, or `NULL` to skip. Reads the
#'   CSVs [md_ingest_f1023ez()] converted, so run that first.
#' @param e_postcard_version Pinned `e_postcard` version, or `NULL` to skip.
#' @return Row counts per source, invisibly.
#' @export
md_ingest_websites <- function(con = NULL, efile_version = NULL,
                               f1023ez_version = NULL, e_postcard_version = NULL) {
  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))
  rd <- function(glob) sprintf(
    "read_csv_auto('%s', ALL_VARCHAR=TRUE, union_by_name=TRUE, quote='\"', escape='\"')",
    gsub("\\\\", "/", glob))
  need <- function(glob, what) {
    if (!length(Sys.glob(glob))) stop("no ", what, " files at ", glob, call. = FALSE)
    glob
  }

  parts <- character(0); versions <- character(0)
  if (!is.null(efile_version)) {
    g <- need(md_path("sources", "efile_header", efile_version, "F9-P00-T00-HEADER-*.CSV"),
              "e-file header")
    parts["efile990"] <- sprintf(
      "SELECT ORG_EIN AS ein_raw, F9_00_ORG_WEBSITE AS url_raw,
              try_cast(TAX_YEAR AS INT) AS yr FROM %s", rd(g))
    versions["efile990"] <- paste0("efile_header-", efile_version)
  }
  if (!is.null(f1023ez_version)) {
    g <- need(md_path("sources", "f1023ez", f1023ez_version, "f1023ez-approvals-*.csv"),
              "converted 1023-EZ")
    parts["f1023ez"] <- sprintf(
      "SELECT Ein AS ein_raw, Orgurl AS url_raw,
              try_cast(regexp_extract(filename, '([0-9]{4})[.]csv$', 1) AS INT) AS yr
       FROM read_csv_auto('%s', ALL_VARCHAR=TRUE, union_by_name=TRUE, filename=TRUE)",
      gsub("\\\\", "/", g))
    versions["f1023ez"] <- paste0("f1023ez-", f1023ez_version)
  }
  if (!is.null(e_postcard_version)) {
    g <- need(md_path("sources", "e_postcard", e_postcard_version, "*-E-POSTCARD.csv"),
              "e-Postcard")
    parts["e_postcard"] <- sprintf(
      "SELECT ein AS ein_raw, website AS url_raw, try_cast(tax_year AS INT) AS yr FROM %s",
      rd(g))
    versions["e_postcard"] <- paste0("e_postcard-", e_postcard_version)
  }
  if (!length(parts)) stop("no website source selected", call. = FALSE)

  union <- paste(sprintf("SELECT '%s' AS source, '%s' AS source_vintage, * FROM (%s)",
                         names(parts), versions[names(parts)], parts),
                 collapse = "\nUNION ALL\n")
  DBI::dbExecute(con, sprintf("
    CREATE OR REPLACE TEMP TABLE web_raw AS
    SELECT source, source_vintage, yr, url_raw,
           'EIN-' || substr(d,1,2) || '-' || substr(d,3,9) AS ein
    FROM (SELECT *, lpad(regexp_replace(coalesce(ein_raw,''),'[^0-9]','','g'), 9, '0') AS d
          FROM (%s))
    WHERE length(regexp_replace(coalesce(ein_raw,''),'[^0-9]','','g')) BETWEEN 1 AND 9
      AND nullif(trim(url_raw), '') IS NOT NULL", union))
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE web_clean AS %s",
                              .md_website_clean_sql("web_raw", "url_raw")))

  stats <- DBI::dbGetQuery(con, "
    SELECT source, count(*) AS filled, count(*) FILTER (WHERE site_key IS NOT NULL) AS valid,
           count(*) FILTER (WHERE site_key IS NOT NULL
                              AND ein NOT IN (SELECT ein FROM entity)) AS no_entity
    FROM web_clean GROUP BY 1 ORDER BY 1")
  for (i in seq_len(nrow(stats))) {
    msg("  %-10s %s non-blank values, %s valid websites, %s held back (EIN not in entity)",
        stats$source[i], format(stats$filled[i], big.mark = ","),
        format(stats$valid[i], big.mark = ","), format(stats$no_entity[i], big.mark = ","))
  }

  DBI::dbExecute(con, "DROP TABLE IF EXISTS website")
  DBI::dbExecute(con, sprintf("
    CREATE TABLE website AS
    WITH kept AS (
      SELECT * FROM web_clean
      WHERE site_key IS NOT NULL AND ein IN (SELECT ein FROM entity)
    ), %s
    , agg AS (
      SELECT ein, site_key, source, any_value(source_vintage) AS source_vintage,
             any_value(host) AS host, any_value(kind) AS kind,
             bool_or(is_platform) AS is_platform,
             count(*) AS n_obs, min(yr) AS first_year, max(yr) AS last_year
      FROM kept GROUP BY ein, site_key, source
    ), sharing AS (
      SELECT site_key, count(DISTINCT ein) AS n_eins_sharing FROM agg GROUP BY 1
    )
    SELECT row_number() OVER (ORDER BY a.ein, a.site_key, a.source) AS website_id,
           a.ein, a.site_key, a.host, m.url, a.kind, a.is_platform, a.source,
           a.source_vintage, a.n_obs, a.first_year, a.last_year, s.n_eins_sharing
    FROM agg a
    JOIN modal_url m ON m.ein = a.ein AND m.site_key = a.site_key
                    AND m.source = a.source AND m.rk = 1
    JOIN sharing s ON s.site_key = a.site_key
    ORDER BY website_id",
    md_modal_sql("kept", c("ein", "site_key", "source"), "url")))
  for (t in c("web_raw", "web_clean")) DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS %s", t))

  out <- DBI::dbGetQuery(con, "
    SELECT source, count(*) AS rows, count(DISTINCT ein) AS eins FROM website GROUP BY 1 ORDER BY 1")
  for (i in seq_len(nrow(out))) {
    msg("  website %-10s %s rows over %s EINs", out$source[i],
        format(out$rows[i], big.mark = ","), format(out$eins[i], big.mark = ","))
  }
  tot <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n, count(DISTINCT ein) AS eins, count(DISTINCT site_key) AS keys,
           count(DISTINCT site_key) FILTER (WHERE n_eins_sharing = 1) AS unique_keys
    FROM website")
  msg("website: %s rows, %s EINs, %s distinct sites of which %s belong to one EIN",
      format(tot$n, big.mark = ","), format(tot$eins, big.mark = ","),
      format(tot$keys, big.mark = ","), format(tot$unique_keys, big.mark = ","))

  vsrc <- c(efile990 = "efile_header", f1023ez = "f1023ez", e_postcard = "e_postcard")
  vver <- c(efile990 = efile_version %||% NA, f1023ez = f1023ez_version %||% NA,
            e_postcard = e_postcard_version %||% NA)
  for (s in out$source) {
    md_record_vintage(con, vsrc[[s]], vver[[s]], paste0("website:", s),
                      as.integer(out$rows[out$source == s]),
                      build_note = "md_ingest_websites()")
  }
  invisible(stats::setNames(out$rows, out$source))
}

# Personal mail providers: a mail address there identifies a person, not an org.
.md_mail_providers <- c("gmail.com", "googlemail.com", "yahoo.com", "ymail.com",
  "hotmail.com", "outlook.com", "live.com", "msn.com", "aol.com", "icloud.com",
  "me.com", "mac.com", "comcast.net", "att.net", "sbcglobal.net", "verizon.net",
  "bellsouth.net", "cox.net", "charter.net", "earthlink.net", "protonmail.com",
  "gmx.com", "mail.com")

# Hosts that serve many organisations' pages: the page path is the identity.
# Matched on the host or any subdomain of it (e.g. foo.wixsite.com).
.md_web_platforms <- c("facebook.com", "fb.com", "fb.me", "instagram.com",
  "twitter.com", "x.com", "linkedin.com", "youtube.com", "tiktok.com",
  "sites.google.com", "google.com", "linktr.ee", "wixsite.com", "wix.com",
  "weebly.com", "wordpress.com", "blogspot.com", "squarespace.com",
  "godaddysites.com", "square.site", "webs.com", "yolasite.com", "jimdo.com",
  "eventbrite.com", "gofundme.com", "paypal.com", "meetup.com",
  "givebutter.com", "networkforgood.org", "classy.org", "guidestar.org",
  "charitynavigator.org", "nextdoor.com", "yelp.com", "github.io",
  "leaguelineup.com", "eteamz.com", "e-clubhouse.org", "sportngin.com",
  "teamsnap.com", "bluesombrero.com", "stacksports.com", "ourchurch.com")

# Platforms that give each page its own subdomain. There the subdomain is the
# identity, and the path (often just /home) is not.
.md_web_subdomain_platforms <- c("wixsite.com", "weebly.com", "wordpress.com",
  "blogspot.com", "godaddysites.com", "square.site", "webs.com", "yolasite.com",
  "jimdo.com", "github.io", "sportngin.com",
  "squarespace.com", "teamsnap.com", "stacksports.com", "ourchurch.com")

# First path segments that name a kind of page, not the page: on these the
# identity is the segment after (sites.google.com/view/troop12,
# facebook.com/groups/123). Measured: sites.google.com/view alone was 897 EINs.
.md_web_generic_segments <- c("view", "site", "sites", "a", "groups", "pages", "page",
  "pg", "share", "p", "people", "profile.php", "events", "org", "u", "c",
  "channel", "user", "company", "school", "in")

# A SELECT over `tbl` that keeps every column and adds host, url, kind,
# is_platform and site_key, all NULL when `col` is not a website. Pure SQL, so
# it is testable on a small table.
.md_website_clean_sql <- function(tbl, col) {
  q <- function(v) paste0("'", v, "'", collapse = ", ")
  # a subdomain of a platform that hosts each page on its own subdomain
  plat_sub <- paste(sprintf("(w_h LIKE '%%.%s')", .md_web_subdomain_platforms), collapse = " OR ")
  plat_match <- paste(sprintf("(w_h = '%s' OR w_h LIKE '%%.%s')", .md_web_platforms,
                              .md_web_platforms), collapse = " OR ")
  sprintf("
    SELECT * EXCLUDE (w_u0, w_u, w_h, w_p, w_kind, w_seg, w_plat, w_plat_sub, w_ok),
           CASE WHEN w_ok THEN w_h END AS host,
           CASE WHEN w_ok THEN rtrim(w_h || w_p, '/') END AS url,
           CASE WHEN w_ok THEN w_kind END AS kind,
           CASE WHEN w_ok THEN w_plat END AS is_platform,
           CASE WHEN NOT w_ok THEN NULL
                -- a page on its own subdomain (mylodge.wixsite.com): the host is the identity
                WHEN w_plat_sub THEN w_h
                WHEN w_plat AND w_seg = '' THEN NULL
                WHEN w_plat THEN w_h || '/' || w_seg
                ELSE w_h END AS site_key
    FROM (
      SELECT *, (%s) AS w_plat, (%s) AS w_plat_sub,
             coalesce(regexp_matches(w_h, '^([a-z0-9]([a-z0-9-]*[a-z0-9])?[.])+[a-z]{2,24}$')
                      AND NOT (w_kind = 'email' AND w_h IN (%s)), FALSE) AS w_ok
      FROM (
        SELECT * EXCLUDE (w_s1, w_s2),
               -- a page file or a search page names no organisation
               CASE WHEN regexp_matches(w_s1, '[.](aspx?|php|html?|cfm|jsp|cgi)$')
                      OR w_s1 IN ('search', 'home', 'index') THEN ''
                    WHEN w_s1 IN (%s) AND w_s2 <> '' THEN w_s1 || '/' || w_s2
                    WHEN w_s1 IN (%s) THEN ''
                    ELSE w_s1 END AS w_seg
        FROM (
        SELECT *, coalesce(lower(regexp_extract(w_p, '^/+([^/?#]+)', 1)), '') AS w_s1,
                  coalesce(lower(regexp_extract(w_p, '^/+[^/?#]+/+([^/?#]+)', 1)), '') AS w_s2
        FROM (
          SELECT *,
                 CASE WHEN w_kind = 'email' THEN regexp_extract(w_u, '@(.*)$', 1)
                      ELSE regexp_replace(regexp_extract(w_u, '^([^/?#]*)', 1), ':[0-9]+$', '')
                 END AS w_h,
                 CASE WHEN w_kind = 'email' THEN ''
                      ELSE regexp_extract(w_u, '^[^/?#]*(.*)$', 1) END AS w_p
          FROM (
            SELECT *,
                   regexp_replace(regexp_replace(w_u0, '^[a-z][a-z0-9+.-]*://', ''),
                                  '^(www[0-9]?|m|mobile|web|business)[.]', '') AS w_u,
                   CASE WHEN regexp_matches(w_u0, '^[^@/ ]+@[^@/ ]+$') THEN 'email'
                        ELSE 'url' END AS w_kind
            FROM (SELECT *, replace(replace(lower(trim(%s)), ',', '.'), chr(92), '/') AS w_u0
                  FROM %s))))))",
    plat_match, plat_sub, q(.md_mail_providers), q(.md_web_generic_segments),
    q(.md_web_generic_segments), col, tbl)
}
