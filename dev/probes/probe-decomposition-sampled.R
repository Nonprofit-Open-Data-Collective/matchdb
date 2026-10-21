suppressMessages({devtools::load_all("."); library(npmatch); library(data.table)})
con <- md_db(read_only=TRUE); on.exit(md_db_close(con))

## EINs with >=2 names and >=2 addresses, both with usable strings
eins <- DBI::dbGetQuery(con, "
  SELECT n.ein FROM (SELECT ein, count(*) k FROM name WHERE name_raw<>'' GROUP BY 1 HAVING count(*) BETWEEN 2 AND 4) n
  JOIN (SELECT ein, count(*) k FROM address WHERE street_raw<>'' AND state IS NOT NULL AND zip5 IS NOT NULL
        GROUP BY 1 HAVING count(*) BETWEEN 2 AND 4) a USING (ein)
  USING SAMPLE 300 ROWS")$ein
q <- paste(sprintf("'%s'", eins), collapse=",")
nm <- setDT(DBI::dbGetQuery(con, sprintf("SELECT ein, name_raw FROM name WHERE ein IN (%s) AND name_raw<>''", q)))
ad <- setDT(DBI::dbGetQuery(con, sprintf("SELECT ein, street_raw, city_raw, state, zip5 FROM address
   WHERE ein IN (%s) AND street_raw<>'' AND state IS NOT NULL AND zip5 IS NOT NULL", q)))
nm[, ni := seq_len(.N), by=ein]; ad[, ai := seq_len(.N), by=ein]
cat(sprintf("%d EINs; %d names, %d addresses\n", length(eins), nrow(nm), nrow(ad)))

## reference = full cross product
ref <- merge(nm, ad, by="ein", allow.cartesian=TRUE)
cat(sprintf("cross-product reference: %d rows (%.1f per EIN)\n\n", nrow(ref), nrow(ref)/length(eins)))
REF <- data.frame(ein=ref$ein, org_name_join=ref$name_raw, dba_name=NA_character_,
  org_addr_street=ref$street_raw, org_addr_city=ref$city_raw, org_addr_state=ref$state,
  org_addr_zip5=ref$zip5, org_addr_zip4=NA_character_, stringsAsFactors=FALSE)
R <- np_normalize(np_reference(REF, map=np_map_bmf()))

## query: FIRST name paired with LAST address -> best name and best geo live in different ref rows
qy <- merge(nm[ni==1, .(ein, qname=name_raw)], ad[, .SD[.N], by=ein], by="ein")
QY <- data.frame(.qid=seq_len(nrow(qy)), ein_true=qy$ein, name=qy$qname, dba=NA_character_,
  street=qy$street_raw, city=qy$city_raw, state=qy$state, zip5=qy$zip5, zip_plus4=NA_character_,
  stringsAsFactors=FALSE)
Q <- np_query(QY, map=c(.id=".qid", name="name", dba="dba", street="street", city="city",
  state="state", zip5="zip5", zip_plus4="zip_plus4"))
Q <- np_normalize(Q)

nf <- np_name_freq(R$name_key)
pairs <- np_compare(Q, R, config=np_config(), block="state", name_freq=nf)
cat(sprintf("candidate pairs: %s\n\n", format(nrow(pairs), big.mark=",")))
sc <- function(ng) np_score(pairs, config=np_config(name_geo=ng), method="hier")$score
d <- data.table(qid=pairs$.x, ein=pairs$.ein_y %||% pairs$.ein,
                s_full=sc(c(name=0.6,geo=0.4)), s_name=sc(c(name=1,geo=0)), s_geo=sc(c(name=0,geo=1)))
if (all(is.na(d$ein))) d[, ein := pairs[[grep("ein", names(pairs), value=TRUE)[1]]]]
agg <- d[, .(A_pairwise = max(s_full),
             B_decomposed = 0.6*max(s_name) + 0.4*max(s_geo)), by=.(qid, ein)]
agg[, delta := B_decomposed - A_pairwise]
cat("=== max-of-sums (A) vs sum-of-maxes (B), per (query, EIN) ===\n")
cat(sprintf("  groups compared : %s\n", format(nrow(agg), big.mark=",")))
cat(sprintf("  exactly equal   : %s (%.1f%%)\n", format(sum(abs(agg$delta)<1e-9), big.mark=","),
    100*mean(abs(agg$delta)<1e-9)))
cat(sprintf("  B > A           : %s\n", format(sum(agg$delta>1e-9), big.mark=",")))
cat(sprintf("  B < A           : %s\n", format(sum(agg$delta< -1e-9), big.mark=",")))
cat(sprintf("  max |delta|     : %.6f\n\n", max(abs(agg$delta))))
if (any(abs(agg$delta)>1e-9)) { cat("--- disagreements ---\n"); print(head(agg[abs(delta)>1e-9][order(-abs(delta))], 8)) }

cat("\n=== did the promotion cross-term actually fire? ===\n")
cfg <- np_config()
nfv <- if (!is.null(pairs$name_freq)) as.numeric(pairs$name_freq) else rep(NA_real_, nrow(pairs))
nsc <- sc(c(name=1, geo=0))
vy  <- if (!is.null(pairs$name_ver_y)) toupper(as.character(pairs$name_ver_y)) else rep(NA_character_, nrow(pairs))
onp <- is.na(vy) | vy == "MAIN"
fired <- !is.na(nfv) & nsc >= 0.95 & nfv <= cfg$distinct_name_maxfreq & onp
cat(sprintf("  pairs with a name_freq : %s\n", format(sum(!is.na(nfv)), big.mark=",")))
cat(sprintf("  promotion fired on     : %s pairs\n", format(sum(fired), big.mark=",")))
cat(sprintf("  groups containing one  : %s\n", format(uniqueN(d[fired, .(qid, ein)]), big.mark=",")))

cat("\n=== did the floor BIND (change a score), or merely fire? ===\n")
gsc <- sc(c(name=0, geo=1))
raw <- 0.6*nsc + 0.4*gsc                       # unfloored weighted sum
gst <- if (!is.null(pairs$cmp_state)) as.numeric(pairs$cmp_state) else rep(NA_real_, nrow(pairs))
fl  <- ifelse(!is.na(gst) & gst == 1, cfg$distinct_name_floor, cfg$distinct_name_floor_xstate)
bindA <- fired & raw < fl                       # floor changes the full score
bindN <- fired & nsc < fl                       # floor changes the name-only score
cat(sprintf("  promoted pairs                    : %s\n", format(sum(fired), big.mark=",")))
cat(sprintf("  floor BINDS in the full-score arm : %s\n", format(sum(bindA, na.rm=TRUE), big.mark=",")))
cat(sprintf("  floor BINDS in the name-only arm  : %s\n", format(sum(bindN, na.rm=TRUE), big.mark=",")))
cat(sprintf("  min raw score among promoted      : %.4f (floor %.2f / %.2f)\n",
    min(raw[fired], na.rm=TRUE), cfg$distinct_name_floor, cfg$distinct_name_floor_xstate))
