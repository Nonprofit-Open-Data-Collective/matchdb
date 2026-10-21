suppressMessages({library(npmatch); library(data.table)})
cfg <- np_config()
## isolate terms with the floor DISABLED, so weight-zeroing actually isolates
bare <- function(ng) np_config(name_geo=ng, distinct_name_floor=0, distinct_name_floor_xstate=0)
run <- function(REF, QY, label) {
  R <- np_normalize(np_reference(REF, map=np_map_bmf()))
  Q <- np_normalize(np_query(QY, map=c(.id=".qid", name="name", dba="dba", street="street",
        city="city", state="state", zip5="zip5", zip_plus4="zip_plus4")))
  nf <- np_name_freq(R$name_key)
  p <- np_compare(Q, R, config=cfg, block="state", name_freq=nf)
  N <- np_score(p, config=bare(c(name=1,geo=0)), method="hier")$score   # pure name
  G <- np_score(p, config=bare(c(name=0,geo=1)), method="hier")$score   # pure geo
  F <- np_score(p, config=cfg, method="hier")$score                     # real, floored
  gst <- if (!is.null(p$geo_state)) as.numeric(p$geo_state) else rep(NA_real_, nrow(p))
  fl  <- ifelse(!is.na(gst) & gst==1, cfg$distinct_name_floor, cfg$distinct_name_floor_xstate)
  prom <- !is.na(p$name_freq) & N >= 0.95 & p$name_freq <= cfg$distinct_name_maxfreq
  A <- max(F)
  Braw <- 0.6*max(N) + 0.4*max(G)
  Bfl  <- if (any(prom)) pmax(Braw, max(fl[prom])) else Braw
  cat(sprintf("%-22s pairs=%d  pureN=%.3f pureG=%.3f | A=%.4f  B_raw=%.4f  B_floored=%.4f  %s\n",
      label, nrow(p), max(N), max(G), A, Braw, Bfl,
      if (abs(Bfl-A)<1e-9) "MATCH" else sprintf("DIVERGE %+.4f", Bfl-A)))
  invisible(abs(Bfl-A) < 1e-9)
}
mk <- function(streets, cities, zips, st="WY")
  data.frame(ein=rep("EIN-99-9999999",length(streets)),
    org_name_join=rep("ZYQXW DISTINCTIVE PHILANTHROPIC TRUST",length(streets)),
    dba_name=NA_character_, org_addr_street=streets, org_addr_city=cities,
    org_addr_state=rep(st,length(streets)), org_addr_zip5=zips,
    org_addr_zip4=NA_character_, stringsAsFactors=FALSE)
qq <- function(nm, street, city, zip, st="WY")
  data.frame(.qid=1L, name=nm, dba=NA_character_, street=street, city=city,
    state=st, zip5=zip, zip_plus4=NA_character_, stringsAsFactors=FALSE)

cat("=== floor-binding region: rare name matches, geography does not ===\n")
run(mk(c("1 ALPHA ST","2 BETA AVE"), c("ALPHAVILLE","BETABURG"), c("82001","82002")),
    qq("ZYQXW DISTINCTIVE PHILANTHROPIC TRUST","999 GAMMA BLVD","GAMMATOWN","83414"), "rare name, bad geo")
cat("\n=== best name and best address on DIFFERENT reference rows ===\n")
REF2 <- data.frame(ein=rep("EIN-99-9999999",4),
  org_name_join=c("ZYQXW DISTINCTIVE PHILANTHROPIC TRUST","ZYQXW DISTINCTIVE PHILANTHROPIC TRUST",
                  "ZYQXW HOLDINGS","ZYQXW HOLDINGS"),
  dba_name=NA_character_, org_addr_street=c("1 ALPHA ST","999 GAMMA BLVD","1 ALPHA ST","999 GAMMA BLVD"),
  org_addr_city=c("ALPHAVILLE","GAMMATOWN","ALPHAVILLE","GAMMATOWN"), org_addr_state=rep("WY",4),
  org_addr_zip5=c("82001","83414","82001","83414"), org_addr_zip4=NA_character_, stringsAsFactors=FALSE)
run(REF2, qq("ZYQXW DISTINCTIVE PHILANTHROPIC TRUST","999 GAMMA BLVD","GAMMATOWN","83414"), "split best name/addr")
cat("\n=== cross-state (the lower floor) ===\n")
run(mk(c("1 ALPHA ST","2 BETA AVE"), c("ALPHAVILLE","BETABURG"), c("82001","82002"), st="WY"),
    qq("ZYQXW DISTINCTIVE PHILANTHROPIC TRUST","999 GAMMA BLVD","GAMMATOWN","83414", st="WY"), "same-state ctrl")
