# The harness has to report zero when nothing changed and non-zero when
# something did. Gate 0d exists because a harness that always passes makes every
# later gate unfalsifiable -- so the self-test is the deliverable, not a
# formality.

ref_frame <- function(n = 6L) {
  data.frame(
    ein        = sprintf("%09d", seq_len(n)),
    name_key   = paste0("ORG ", LETTERS[seq_len(n)]),
    street_key = paste0(seq_len(n), " MAIN ST"),
    zip5       = sprintf("%05d", 10000 + seq_len(n)),
    city       = rep("JUNEAU", n),
    state      = rep("AK", n),
    active     = rep(c(TRUE, FALSE), length.out = n),
    stringsAsFactors = FALSE)
}
COLS <- c("ein", "name_key", "street_key", "zip5", "city", "state", "active")

test_that("a frame compared with itself reports three zeros", {
  d <- md_compare_frames(ref_frame(), ref_frame(), COLS)
  expect_true(d$passed)
  expect_identical(d$n_only_baseline, 0L)
  expect_identical(d$n_only_candidate, 0L)
  expect_identical(d$n_cells_differ, 0L)
})

test_that("representational differences are absorbed, not reported", {
  b <- ref_frame()
  # row order, column order, factor vs character, "" vs NA, logical vs character
  cand <- b[rev(seq_len(nrow(b))), rev(names(b))]
  cand$name_key <- factor(cand$name_key)
  cand$active   <- as.character(cand$active)
  cand$city[cand$city == "JUNEAU"] <- "JUNEAU"
  b$state[1] <- ""; cand$state[cand$ein == b$ein[1]] <- NA
  expect_true(md_compare_frames(b, cand, COLS)$passed)
})

test_that("a changed value is caught and attributed to its column", {
  b <- ref_frame(); cand <- b
  cand$city[3] <- "ANCHORAGE"
  d <- md_compare_frames(b, cand, COLS)
  expect_false(d$passed)
  expect_identical(d$n_cells_differ, 1L)
  expect_identical(names(d$per_column), "city")
})

test_that("added and removed rows are reported on the correct side", {
  b <- ref_frame()
  d1 <- md_compare_frames(b, b[-2, ], COLS)
  expect_identical(d1$n_only_baseline, 1L); expect_identical(d1$n_only_candidate, 0L)
  d2 <- md_compare_frames(b[-2, ], b, COLS)
  expect_identical(d2$n_only_baseline, 0L); expect_identical(d2$n_only_candidate, 1L)
})

test_that("duplicate keys are compared as a multiset, not collapsed", {
  b <- rbind(ref_frame(2), ref_frame(2))          # each key twice
  cand <- rbind(ref_frame(2), ref_frame(2)[1, ])  # one key once
  d <- md_compare_frames(b, cand, COLS)
  expect_false(d$passed)
  expect_identical(d$n_only_baseline, 1L)
})

test_that("the pinned column list is required and enforced", {
  b <- ref_frame()
  expect_error(md_compare_frames(b, b), "`columns` is required")
  expect_error(md_compare_frames(b, b[, -5], COLS), "missing pinned column")
})

# --- tiered outputs --------------------------------------------------------

tiered <- function(ids, tier = "YES") {
  data.frame(.id = as.character(ids), overall_ein = sprintf("%09d", ids),
             tier = tier, decision_score = 0.9, stringsAsFactors = FALSE)
}

test_that("a tiered frame compared with itself passes", {
  expect_true(md_compare_tiered(tiered(1:5), tiered(1:5))$passed)
})

test_that("identities absent on one side read as NONE, not as a rejection", {
  # the union-align rule: a bigger reference reaches more identities, and the
  # extra ones must not be silently treated as scored NOs
  d <- md_compare_tiered(tiered(1:5), tiered(1:6))
  expect_false(d$passed)
  expect_identical(d$n_only_baseline, 1L)
  expect_true("tier" %in% names(d$per_column))
  expect_true(any(d$sample_cells$baseline == "NONE"))
})

test_that("a changed tier is caught", {
  b <- tiered(1:5); cand <- b; cand$tier[2] <- "MAYBE"
  d <- md_compare_tiered(b, cand)
  expect_false(d$passed)
  expect_identical(d$n_cells_differ, 1L)
})

test_that("NONE and NO are distinguished", {
  b <- tiered(1:5); b$tier[3] <- "NO"
  cand <- b[-3, ]                       # identity 3 drew no candidate at all
  d <- md_compare_tiered(b, cand)
  expect_false(d$passed)                # NO -> NONE is a real difference
})
