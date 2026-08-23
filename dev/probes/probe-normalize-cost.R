suppressMessages({devtools::load_all("."); library(npmatch)})
con <- md_db(read_only=TRUE); on.exit(md_db_close(con))
N <- 200000L
nm <- DBI::dbGetQuery(con, sprintf("SELECT name_id, ein, name_raw FROM name USING SAMPLE %d ROWS", N))
ad <- DBI::dbGetQuery(con, sprintf("SELECT address_id, ein, street_raw, city_raw, state, zip5, zip_plus4 FROM address USING SAMPLE %d ROWS", N))
cat("sampled", nrow(nm), "names,", nrow(ad), "addresses\n\n")

stub <- function(n) rep("", n)
fn <- data.frame(name = nm$name_raw, dba = stub(nrow(nm)), division = stub(nrow(nm)),
                 street = stub(nrow(nm)), zip5 = stub(nrow(nm)),
                 zip_plus4 = stub(nrow(nm)), state = stub(nrow(nm)),
                 stringsAsFactors = FALSE)
t0 <- Sys.time(); on <- np_normalize(fn); t_name <- as.numeric(difftime(Sys.time(), t0, units="secs"))

fa <- data.frame(name = stub(nrow(ad)), dba = stub(nrow(ad)), division = stub(nrow(ad)),
                 street = ad$street_raw, zip5 = ad$zip5,
                 zip_plus4 = ifelse(is.na(ad$zip_plus4), "", ad$zip_plus4),
                 state = ifelse(is.na(ad$state), "", ad$state), stringsAsFactors = FALSE)
t0 <- Sys.time(); oa <- np_normalize(fa); t_addr <- as.numeric(difftime(Sys.time(), t0, units="secs"))

cat(sprintf("name pass : %6.1f s for %s rows\n", t_name, format(nrow(nm), big.mark=",")))
cat(sprintf("addr pass : %6.1f s for %s rows\n\n", t_addr, format(nrow(ad), big.mark=",")))
cat(sprintf("EXTRAPOLATED to full tables:\n  name  9,665,441 rows -> %5.1f min\n  address 18,546,417 rows -> %5.1f min\n  TOTAL -> %.1f min\n\n",
  t_name/nrow(nm)*9665441/60, t_addr/nrow(ad)*18546417/60,
  (t_name/nrow(nm)*9665441 + t_addr/nrow(ad)*18546417)/60))

newn <- setdiff(names(on), names(fn)); newa <- setdiff(names(oa), names(fa))
cat("NAME-derived columns (", length(newn), "):\n  ", paste(newn, collapse=", "), "\n\n")
cat("ADDRESS-derived columns (", length(newa), "):\n  ", paste(newa, collapse=", "), "\n\n")
cat("--- name examples ---\n")
print(head(on[nchar(on$name_raw <- fn$name) > 20, c("name","name_key","name_form","name_gen")], 4))
cat("\n--- address examples ---\n")
print(head(oa[oa$street != "", c("street","street_key","street_num","street_type","zip5","zip3")], 4))
cat("\n--- signature ---\n"); cat(np_normalize_signature(), "\n")
