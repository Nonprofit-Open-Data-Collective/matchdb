#' Build the cluster layer: typed, many-to-many families of EINs
#'
#' Writes `cluster` (one row per cluster), `cluster_member` (one row per
#' cluster and EIN) and `cluster_footprint` (members per cluster, layer and
#' state). An EIN can belong to many clusters, of different types. A chapter
#' that is hard to match on its own can then be matched one level up: a query
#' whose name matches one member and whose address matches another is still a
#' strong match to the cluster.
#'
#' @section Cluster types:
#' \describe{
#'   \item{`group_exemption` (`GRP-`)}{the components of `entity_group` - see
#'     [md_build_groups()]. Central is `group_central_ein`.}
#'   \item{`related_system` (`SYS-`)}{one cluster per Schedule R discloser: the
#'     filer and every related or disregarded entity it lists that is in
#'     `entity`. A star, never a connected component: chained together these
#'     edges form one component of 117,869 EINs across the health and
#'     university sectors. Overlapping stars are kept as they are.}
#'   \item{`care_of_network` (`ICO-`)}{one cluster per organisation named in
#'     other EINs' in-care-of field. Only values that read as an organisation
#'     are used: not a person (census first name and surname), not a role
#'     (`TREASURER`), not an agent (bank, trust company, CPA, law firm); naming
#'     exactly one EIN's legal or dba name, of two or more words, in the same
#'     state. Needs the `peopleparser` census name table.}
#'   \item{`shared_website` (`WEB-`)}{one cluster per website key held by two
#'     or more EINs (at most `max_website`). A national body's site written by
#'     its chapters.}
#'   \item{`brand` (`BRD-`)}{one cluster per brand word: a name word that is
#'     concentrated in one name, the way `TOASTMASTERS` is, rather than spread
#'     across many, the way `BAPTIST` is. A word is a brand when one full name
#'     holds at least `brand_min_share` of the EINs carrying the word, and that
#'     name is held by at least `brand_min_eins` EINs. Each dominant name gives
#'     one brand, anchored on its most concentrated word: `LIONS`, not `CLUBS`;
#'     `AMATEUR`, not `STATES`. A first pass let every word of a dominant name
#'     be its own brand, and `STATES` gathered 42,951 EINs. Members are every
#'     EIN whose legal or dba name contains the anchor word. This is what
#'     reaches the 63% of Toastmasters clubs that are in no group exemption.}
#'   \item{`co_tenant` (`CTN-`)}{one cluster per street address shared by 2 to
#'     `max_cotenants` EINs: a school and its PTO, a hospital and its
#'     foundation. Larger shared places are registered agents and processing
#'     centres, which say nothing about affiliation.}
#' }
#'
#' @section Columns:
#' `cluster`: `cluster_id`, `cluster_type`, `central_ein` (NULL where the type
#' has none), `size`, `label` (the central EIN's legal name, or the shared key)
#' and `brand_tokens` (name words held by at least half the members, for
#' clusters of three or more).
#'
#' `cluster_member`: `cluster_id`, `ein`, `role` (`central`, `parent`,
#' `intermediate` or `member`) and `evidence`.
#'
#' `cluster_footprint`: `cluster_id`, `layer`, `state`, `n_eins`. Layers
#' partition EINs, so the footprint of any selection of layers is the exact sum
#' of its rows - the same rule as `ein_key_layer`.
#'
#' @section What this does not do:
#' It does not nest clusters into levels (chapter, state body, national), and
#' it does not merge overlapping clusters. Both are left to the consumer, which
#' can see every membership.
#'
#' @param con A connection from [md_db()].
#' @param types Which cluster types to build.
#' @param max_cotenants Largest shared place that still counts as co-tenancy.
#' @param max_website Largest website key that still forms a cluster.
#' @param brand_min_share,brand_min_eins The brand-word thresholds above.
#' @param brand_alone_share An anchor this concentrated needs no second
#'   word of the brand name to make an EIN a member.
#' @return Clusters and memberships per type, invisibly.
#' @export
md_build_clusters <- function(con = NULL,
    types = c("group_exemption", "related_system", "care_of_network",
              "shared_website", "brand", "co_tenant"),
    max_cotenants = 3L, max_website = 5000L,
    brand_min_share = 0.5, brand_min_eins = 10L, brand_alone_share = 0.8) {
  types <- match.arg(types, several.ok = TRUE)
  own <- is.null(con)
  if (own) { con <- md_db(); on.exit(md_db_close(con), add = TRUE) }
  msg <- function(...) message(sprintf(...))
  digits <- function(col) sprintf("substr(%s, 5)", col)   # EIN-12-3456789 -> 12-3456789

  .md_placeholder_macro(con)
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE cl_mem (
    cluster_id VARCHAR, cluster_type VARCHAR, ein VARCHAR, role VARCHAR,
    evidence VARCHAR, central_ein VARCHAR, label VARCHAR)")
  add <- function(sql) DBI::dbExecute(con, paste("INSERT INTO cl_mem", sql))

  if ("group_exemption" %in% types) {
    add("SELECT group_id, 'group_exemption', ein,
                CASE WHEN ein = group_central_ein THEN 'central'
                     WHEN role = 'parent' THEN 'parent'
                     WHEN role = 'both' THEN 'intermediate' ELSE 'member' END,
                'group_member', group_central_ein, NULL
         FROM entity_group")
  }

  if ("related_system" %in% types) {
    DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE cl_sys AS
      SELECT r.ein_a, r.ein_b, string_agg(DISTINCT r.evidence, ';' ORDER BY r.evidence) AS ev
      FROM ein_relation r
      WHERE r.relation IN ('related_entity', 'disregarded_entity')
        AND r.ein_b IS NOT NULL AND r.ein_a <> r.ein_b
        AND r.ein_b IN (SELECT ein FROM entity) AND r.ein_a IN (SELECT ein FROM entity)
        AND NOT md_placeholder_ein(r.ein_a) AND NOT md_placeholder_ein(r.ein_b)
      GROUP BY 1, 2")
    add(sprintf("SELECT DISTINCT 'SYS-' || %s, 'related_system', ein_a, 'central',
                'schedule_r_discloser', ein_a, NULL FROM cl_sys", digits("ein_a")))
    add(sprintf("SELECT 'SYS-' || %s, 'related_system', ein_b, 'member', ev, ein_a, NULL
                 FROM cl_sys", digits("ein_a")))
  }

  if ("care_of_network" %in% types) {
    .md_care_of_links(con)
    add(sprintf("SELECT DISTINCT 'ICO-' || %s, 'care_of_network', target, 'central',
                'named_in_care_of', target, NULL FROM cl_ico", digits("target")))
    add(sprintf("SELECT 'ICO-' || %s, 'care_of_network', ein, 'member',
                'in_care_of:' || source, target, NULL FROM cl_ico", digits("target")))
  }

  if ("shared_website" %in% types) {
    add(sprintf("SELECT 'WEB-' || key, 'shared_website', ein, 'member', kind, NULL, key
                 FROM ein_key WHERE kind IN ('website', 'email_domain')
                   AND n_eins_sharing BETWEEN 2 AND %d", as.integer(max_website)))
  }

  if ("brand" %in% types) {
    .md_brand_words(con, brand_min_share, brand_min_eins)
    # An anchor found almost nowhere else (TOASTMASTERS) is enough on its own.
    # One with other uses (COLUMBUS, LIONS) also needs a second word of the
    # brand's name, trailing S ignored, so SPRINGFIELD LIONS CLUB is in and
    # DETROIT LIONS and COLUMBUS SYMPHONY are not.
    add(sprintf("SELECT 'BRD-' || b.word, 'brand', t.ein, 'member', 'name_word', NULL, b.word
         FROM cl_brand b JOIN cl_tok t USING (word)
         WHERE b.top_share >= %f OR EXISTS (
           SELECT 1 FROM cl_bw w JOIN cl_all a ON a.stem = w.bstem
           WHERE w.word = b.word AND a.ein = t.ein)", brand_alone_share))
  }

  if ("co_tenant" %in% types) {
    # Where md_build_places() has run, only a plain cluster place forms a
    # family: an accountant's c/o address, a mailbox store or an agent's
    # address with a churning client list holds unrelated organisations however
    # few there are (dev/PLACES.md section 6). ein_key writes a place as
    # street_key|zip5, place as npmatch's "street_key zip5".
    not_family <- if (DBI::dbExistsTable(con, "place")) "
                 AND NOT EXISTS (SELECT 1 FROM place p
                   WHERE p.place_key = replace(ein_key.key, '|', ' ')
                     AND (p.place_class <> 'cluster' OR p.flag_care_of OR p.flag_cmra
                          OR p.flag_bank_trust OR p.flag_agent_churn))" else ""
    add(sprintf("SELECT 'CTN-' || key, 'co_tenant', ein, 'member', 'shared_place', NULL, key
                 FROM ein_key WHERE kind = 'place' AND n_eins_sharing BETWEEN 2 AND %d%s",
                as.integer(max_cotenants), not_family))
  }

  ## ---- write the three tables ---------------------------------------------------
  DBI::dbExecute(con, "DROP TABLE IF EXISTS cluster_member")
  DBI::dbExecute(con, "
    CREATE TABLE cluster_member AS
    SELECT cluster_id, ein,
           -- one row per (cluster, ein): the strongest role wins
           arg_min(role, CASE role WHEN 'central' THEN 1 WHEN 'parent' THEN 2
                                   WHEN 'intermediate' THEN 3 ELSE 4 END) AS role,
           string_agg(DISTINCT evidence, ';' ORDER BY evidence) AS evidence
    -- members must be known entities: group edges can name a subordinate
    -- that is not in entity (the affiliate listing has 9)
    -- and real: a placeholder EIN (0, 123456789) written by many filers is not
    -- an organisation, and every cluster that holds it would be a false family
    FROM cl_mem WHERE ein IN (SELECT ein FROM entity) AND NOT md_placeholder_ein(ein)
    GROUP BY cluster_id, ein
    ORDER BY cluster_id, ein")

  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE cl_legal AS
    SELECT ein, min(name_raw) AS legal FROM name
    WHERE variant_class = 'legal' AND source = 'bmf' GROUP BY 1")
  DBI::dbExecute(con, "DROP TABLE IF EXISTS cluster")
  DBI::dbExecute(con, "
    CREATE TABLE cluster AS
    WITH h AS (
      SELECT cluster_id, any_value(cluster_type) AS cluster_type,
             max(central_ein) AS central_ein, max(label) AS key_label
      FROM cl_mem GROUP BY 1
    ), s AS (SELECT cluster_id, count(*) AS size FROM cluster_member GROUP BY 1)
    SELECT h.cluster_id, h.cluster_type, h.central_ein, s.size,
           coalesce(l.legal, h.key_label) AS label, NULL::VARCHAR AS brand_tokens
    FROM h JOIN s USING (cluster_id) LEFT JOIN cl_legal l ON l.ein = h.central_ein
    WHERE s.size >= 2
    ORDER BY h.cluster_id")
  # A star whose only listed entities fell outside `entity` is one EIN, not a cluster.
  DBI::dbExecute(con, "DELETE FROM cluster_member
                       WHERE cluster_id NOT IN (SELECT cluster_id FROM cluster)")

  # Brand tokens: name words held by at least half the members of a cluster of
  # three or more. The words a cluster-level name comparison would look for.
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE cl_words AS
    SELECT DISTINCT ein, unnest(string_split(name_key, ' ')) AS word
    FROM name_compact WHERE variant_class IN ('legal', 'dba')")
  DBI::dbExecute(con, "
    UPDATE cluster c SET brand_tokens = b.tokens
    FROM (
      SELECT cluster_id, string_agg(word, ' ' ORDER BY n DESC, word) AS tokens
      FROM (
        SELECT m.cluster_id, w.word, count(DISTINCT m.ein) AS n, any_value(c.size) AS size
        FROM cluster_member m JOIN cluster c USING (cluster_id)
        JOIN cl_words w ON w.ein = m.ein
        WHERE c.size >= 3 AND length(w.word) >= 2
        GROUP BY 1, 2)
      WHERE n * 2 >= size
      GROUP BY 1) b
    WHERE c.cluster_id = b.cluster_id")

  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE cl_state AS
    SELECT ein, arg_min(state, {a: -n, b: state}) AS state FROM (
      SELECT ein, state, sum(n_obs) AS n FROM address_compact
      WHERE coalesce(state, '') <> '' GROUP BY 1, 2) GROUP BY 1")
  DBI::dbExecute(con, "DROP TABLE IF EXISTS cluster_footprint")
  DBI::dbExecute(con, "
    CREATE TABLE cluster_footprint AS
    SELECT m.cluster_id, e.layer, s.state, count(*) AS n_eins
    FROM cluster_member m JOIN entity e USING (ein) LEFT JOIN cl_state s USING (ein)
    GROUP BY 1, 2, 3 ORDER BY 1, 2, 3")

  for (t in c("cl_mem", "cl_sys", "cl_ico", "cl_tok", "cl_brand", "cl_bw", "cl_all", "cl_legal",
              "cl_words", "cl_state", "ico", "ico_c")) {
    DBI::dbExecute(con, sprintf("DROP TABLE IF EXISTS %s", t))
  }

  out <- DBI::dbGetQuery(con, "
    SELECT c.cluster_type, count(DISTINCT c.cluster_id) AS clusters,
           sum(c.size) AS memberships, max(c.size) AS largest,
           median(c.size) AS median_size
    FROM cluster c GROUP BY 1 ORDER BY 1")
  for (i in seq_len(nrow(out))) {
    msg("  cluster %-16s %s clusters, %s memberships, median %s, largest %s",
        out$cluster_type[i], format(out$clusters[i], big.mark = ","),
        format(out$memberships[i], big.mark = ","), format(out$median_size[i]),
        format(out$largest[i], big.mark = ","))
  }
  n_eins <- DBI::dbGetQuery(con, "SELECT count(DISTINCT ein) AS n FROM cluster_member")$n
  msg("cluster: %s clusters over %s EINs", format(.md_n(con, "cluster"), big.mark = ","),
      format(n_eins, big.mark = ","))
  invisible(out)
}

# In-care-of values that name one other organisation. Writes temp table cl_ico
# (ein, target, source): `ein`'s in-care-of field names `target`'s legal or dba
# name. The classification and its measured counts are in the roxygen above.
.md_care_of_links <- function(con) {
  if (!requireNamespace("peopleparser", quietly = TRUE)) {
    stop("care_of_network needs the peopleparser census name table: ",
         "install peopleparser, or drop the type", call. = FALSE)
  }
  env <- new.env()
  utils::data("census.names", package = "peopleparser", envir = env)
  cn <- as.data.frame(env$census.names)
  cn <- data.frame(name = toupper(cn$name), first = cn$first_name_value > 0,
                   last = cn$last_name_value > 0, stringsAsFactors = FALSE)
  duckdb::duckdb_register(con, "cl_census", cn)
  on.exit(duckdb::duckdb_unregister(con, "cl_census"), add = TRUE)

  words <- function(x) paste(x, collapse = "|")
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE ico AS
    SELECT n.ein, n.source, d.name_key, string_split(d.name_key, ' ') AS toks
    FROM name n JOIN name_derived d USING (name_id)
    WHERE n.variant_class = 'in_care_of' AND d.name_key <> ''")
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE cl_cn AS
    SELECT name, bool_or(first) AS first, bool_or(last) AS last FROM cl_census GROUP BY 1")
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE ico_c AS
    SELECT i.*, len(i.toks) AS ntok,
      regexp_matches(i.name_key, '(^| )(%s)( |$)') AS has_role,
      regexp_matches(i.name_key, '(^| )(%s)( |$)') AS has_agent,
      coalesce(f.first, FALSE) AS given, coalesce(l.last, FALSE) AS surname
    FROM ico i
    LEFT JOIN cl_cn f ON f.name = i.toks[1]
    LEFT JOIN cl_cn l ON l.name = i.toks[len(i.toks)]", words(.md_ico_roles),
    words(.md_ico_agents)))
  DBI::dbExecute(con, "DROP TABLE cl_cn")
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE cl_ico AS
    WITH named AS (
      SELECT d.name_key, min(n.ein) AS target, count(DISTINCT n.ein) AS n_eins
      FROM name n JOIN name_derived d USING (name_id)
      WHERE n.variant_class IN ('legal', 'dba') GROUP BY 1
    ), st AS (
      SELECT ein, arg_min(state, {a: -n, b: state}) AS state FROM (
        SELECT ein, state, count(*) AS n FROM address
        WHERE coalesce(state, '') <> '' GROUP BY 1, 2) GROUP BY 1
    )
    SELECT DISTINCT c.ein, nm.target, c.source
    FROM ico_c c JOIN named nm USING (name_key)
    JOIN st sa ON sa.ein = c.ein JOIN st sb ON sb.ein = nm.target
    WHERE nm.n_eins = 1 AND nm.target <> c.ein AND c.ntok >= 2
      AND NOT c.has_role AND NOT c.has_agent
      AND NOT (c.given AND c.surname AND c.ntok <= 5)
      AND sa.state = sb.state")
}

# Words that make an in-care-of value a role or a titled person, not an org.
.md_ico_roles <- c("TREASURER", "PRESIDENT", "SECRETARY", "DIRECTOR", "PASTOR",
  "OFFICER", "CFO", "CEO", "COO", "CHAIR", "CHAIRMAN", "CHAIRPERSON", "MANAGER",
  "ADMINISTRATOR", "COORDINATOR", "ACCOUNTANT", "BOOKKEEPER", "TRUSTEE", "TTEE",
  "TRS", "TR", "EXECUTOR", "AGENT", "ATTN", "REGISTRAR", "CLERK", "COMMANDER",
  "ADJUTANT", "QUARTERMASTER", "RECTOR", "VICAR", "BISHOP", "REV", "REVEREND",
  "FATHER", "SISTER", "DEAN", "PRINCIPAL", "SUPERINTENDENT", "TAX", "DEPT",
  "DEPARTMENT", "OFFICE", "PTA", "PTO", "PEO", "ETAL", "JR", "SR", "II", "III",
  "IV", "MD", "DDS", "ESQ", "PHD", "RN")

# Words that make an in-care-of value an agent: a bank, trust company, CPA or
# law firm serves many unrelated clients, so it is never an affiliation.
.md_ico_agents <- c("BANK", "BANCORP", "TRUST CO", "TRUST COMPANY",
  "NATIONAL ASSOCIATION", "N A", "NA", "WELLS FARGO", "JPMORGAN", "CHASE",
  "CITIBANK", "MELLON", "NORTHERN TRUST", "US BANK", "PNC", "FIDUCIARY",
  "FOUNDATION SOURCE", "CPA", "CPAS", "LLP", "PLLC", "PC", "PA", "LAW", "ATTORNEY",
  "ATTORNEYS", "ACCOUNTING", "ACCOUNTANTS", "TAX SERVICE", "TAX SERVICES",
  "PAYROLL", "WEALTH", "CAPITAL MANAGEMENT", "ADVISORS", "INVESTMENT",
  "INVESTMENTS", "SECURITIES", "MERRILL", "SCHWAB", "FIDELITY", "VANGUARD",
  "MORGAN STANLEY", "UBS", "RAYMOND JAMES", "EDWARD JONES", "INSURANCE", "REALTY",
  "PROPERTY MANAGEMENT", "MANAGEMENT CO", "MANAGEMENT COMPANY", "MANAGEMENT INC")

# Brand words. Writes temp tables cl_tok (ein, word) over legal and dba names,
# and cl_brand (word, top_key, top_share, df).
.md_brand_words <- function(con, min_share, min_eins) {
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE cl_keys AS
    SELECT DISTINCT ein, name_key FROM name_compact
    WHERE variant_class IN ('legal', 'dba') AND name_key <> ''")
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE cl_tok AS
    SELECT DISTINCT ein, word FROM (
      SELECT ein, unnest(string_split(name_key, ' ')) AS word FROM cl_keys)
    WHERE length(word) >= 4 AND NOT regexp_matches(word, '[0-9]')")
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE cl_brand AS
    WITH df AS (SELECT word, count(*) AS df FROM cl_tok GROUP BY 1),
    keyed AS (
      SELECT t.word, k.name_key, count(DISTINCT k.ein) AS n
      FROM cl_tok t JOIN cl_keys k USING (ein)
      WHERE (' ' || k.name_key || ' ') LIKE ('%% ' || t.word || ' %%')
      GROUP BY 1, 2
    ), top AS (SELECT word, arg_min(name_key, {a: -n, b: name_key}) AS top_key, max(n) AS top_n FROM keyed GROUP BY 1),
    cand AS (
      SELECT top.word, top.top_key, top.top_n, df.df, top.top_n / df.df AS top_share
      FROM top JOIN df USING (word)
      WHERE top.top_n >= %d AND top.top_n / df.df >= %f
    )
    -- One brand per dominant name, anchored on its most concentrated word. The
    -- name's other words (STATES and UNITED in AMATEUR ATHLETIC UNION OF THE
    -- UNITED STATES) are concentrated only because this name dominates them,
    -- and as anchors they would gather every organisation using the word.
    SELECT word, top_key, top_n, df, top_share FROM (
      SELECT *, row_number() OVER (PARTITION BY top_key
                                   ORDER BY top_share DESC, df, word) AS rk
      FROM cand) WHERE rk = 1",
    as.integer(min_eins), min_share))
  # A placeholder held as a legal name by many EINs (NOT APPLICABLE) is
  # concentrated too, and is no brand.
  b <- DBI::dbGetQuery(con, "SELECT word, top_key FROM cl_brand")
  junk <- b$word[npnormalize::np_name_placeholder(b$top_key) %in% TRUE]
  if (length(junk)) {
    DBI::dbExecute(con, sprintf("DELETE FROM cl_brand WHERE word IN (%s)",
                                paste0("'", gsub("'", "''", junk), "'", collapse = ", ")))
  }

  # The brand's other words, and every word of every legal or dba name, for the
  # second-word test in md_build_clusters().
  DBI::dbExecute(con, sprintf("CREATE OR REPLACE TEMP TABLE cl_bw AS
    SELECT DISTINCT word, bw, regexp_replace(bw, 'S$', '') AS bstem FROM (
      SELECT word, unnest(string_split(top_key, ' ')) AS bw FROM cl_brand)
    WHERE bw <> word AND length(bw) >= 3 AND NOT regexp_matches(bw, '[0-9]')
      AND bw NOT IN (%s)", paste0("'", .md_brand_stop, "'", collapse = ", ")))
  DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE cl_all AS
    SELECT DISTINCT ein, regexp_replace(w, 'S$', '') AS stem FROM (
      SELECT ein, unnest(string_split(name_key, ' ')) AS w FROM cl_keys)")
  DBI::dbExecute(con, "DROP TABLE IF EXISTS cl_keys")
}

# Words too common to count as the second word of a brand's name.
.md_brand_stop <- c("THE", "AND", "FOR", "INC", "OF", "IN", "AT", "TO", "USA", "INCORPORATED")
