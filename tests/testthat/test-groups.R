# group_id is connected components over group_member edges only. The cases
# below are the ones a naive build gets wrong: edges of the wrong type joining
# families, a member under two parents, chains longer than one hop, and ids
# that move when unrelated groups are added.

e <- function(n) sprintf("EIN-00-%07d", n)

rel_db <- function(rows) {
  con <- DBI::dbConnect(duckdb::duckdb())
  DBI::dbExecute(con, "CREATE TABLE ein_relation (ein_a VARCHAR, ein_b VARCHAR,
                                                  relation VARCHAR)")
  if (nrow(rows)) DBI::dbAppendTable(con, "ein_relation", rows)
  con
}

edges <- function(a, b, relation = "group_member") {
  data.frame(ein_a = a, ein_b = b, relation = relation, stringsAsFactors = FALSE)
}

groups <- function(con) {
  DBI::dbGetQuery(con, "SELECT * FROM entity_group ORDER BY ein")
}

test_that("a star is one group, named after its smallest EIN", {
  skip_if_not_installed("duckdb")
  con <- rel_db(edges(e(5), e(c(7, 3, 9))))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  suppressMessages(md_build_groups(con))
  g <- groups(con)

  expect_equal(g$ein, e(c(3, 5, 7, 9)))
  expect_equal(unique(g$group_id), "GRP-00-0000003")
  expect_equal(unique(g$group_size), 4)
  expect_equal(g$role[g$ein == e(5)], "parent")
  expect_true(all(g$role[g$ein != e(5)] == "member"))
  # the id names the smallest EIN, which is a member - the parent is a column
  expect_equal(unique(g$group_central_ein), e(5))
})

test_that("separate stars stay separate", {
  skip_if_not_installed("duckdb")
  con <- rel_db(rbind(edges(e(1), e(c(2, 3))), edges(e(10), e(c(11, 12)))))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  out <- suppressMessages(md_build_groups(con))
  g <- groups(con)

  expect_equal(out$groups, 2)
  expect_equal(g$group_id[g$ein == e(3)], "GRP-00-0000001")
  expect_equal(g$group_id[g$ein == e(12)], "GRP-00-0000010")
})

test_that("related_entity and disregarded_entity edges never join groups", {
  skip_if_not_installed("duckdb")
  # without the relation filter these two families would be one component
  con <- rel_db(rbind(edges(e(1), e(2)), edges(e(10), e(11)),
                      edges(e(2), e(11), "related_entity"),
                      edges(e(1), e(10), "disregarded_entity"),
                      edges(e(20), e(21), "related_entity")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  out <- suppressMessages(md_build_groups(con))
  g <- groups(con)

  expect_equal(out$groups, 2)
  expect_false(e(20) %in% g$ein)
  expect_false(g$group_id[g$ein == e(2)] == g$group_id[g$ein == e(11)])
})

test_that("a member under two parents joins their groups", {
  skip_if_not_installed("duckdb")
  # e(3) is listed by both parents, e.g. a subordinate carried under two GENs
  con <- rel_db(rbind(edges(e(1), e(c(2, 3))), edges(e(10), e(c(3, 11)))))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  out <- suppressMessages(md_build_groups(con))
  g <- groups(con)

  expect_equal(out$groups, 1)
  expect_equal(unique(g$group_size), 5)
  expect_equal(g$n_parents[g$ein == e(3)], 2)
  expect_equal(g$n_parents[g$ein == e(2)], 1)
  expect_equal(g$n_parents[g$ein == e(1)], 0)
})

test_that("central EIN is the parent with most members, ties to the smaller", {
  skip_if_not_installed("duckdb")
  con <- rel_db(rbind(edges(e(8), e(c(2, 3))), edges(e(4), e(c(3, 5))),
                      edges(e(9), e(c(5, 6, 7)))))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  suppressMessages(md_build_groups(con))
  expect_equal(unique(groups(con)$group_central_ein), e(9))

  con2 <- rel_db(rbind(edges(e(8), e(c(2, 3))), edges(e(4), e(c(3, 5)))))
  on.exit(DBI::dbDisconnect(con2, shutdown = TRUE), add = TRUE)
  suppressMessages(md_build_groups(con2))
  expect_equal(unique(groups(con2)$group_central_ein), e(4))
})

test_that("an intermediate that is both parent and member is role 'both'", {
  skip_if_not_installed("duckdb")
  con <- rel_db(rbind(edges(e(1), e(2)), edges(e(2), e(3))))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  suppressMessages(md_build_groups(con))
  g <- groups(con)
  expect_equal(g$role, c("parent", "both", "member"))
})

test_that("a long chain converges to one group, and max_iter is enforced", {
  skip_if_not_installed("duckdb")
  # labels move one hop per pass, so a chain is the slowest case
  con <- rel_db(edges(e(2:30), e(1:29)))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  out <- suppressMessages(md_build_groups(con))
  expect_equal(out$groups, 1)
  expect_equal(unique(groups(con)$group_id), "GRP-00-0000001")
  expect_gt(out$passes, 10)

  expect_error(suppressMessages(md_build_groups(con, max_iter = 3)),
               "did not converge")
})

test_that("NULL counterparties, self-loops and duplicate edges are ignored", {
  skip_if_not_installed("duckdb")
  con <- rel_db(rbind(edges(e(1), c(e(2), e(2), NA, e(1))), edges(e(7), NA)))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  out <- suppressMessages(md_build_groups(con))
  g <- groups(con)

  expect_equal(out$edges, 1)
  expect_equal(g$ein, e(1:2))
  expect_false(e(7) %in% g$ein)
})

test_that("rebuilding is idempotent, and an unrelated group moves no id", {
  skip_if_not_installed("duckdb")
  con <- rel_db(rbind(edges(e(50), e(c(51, 52))), edges(e(60), e(61))))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  suppressMessages(md_build_groups(con))
  first <- groups(con)
  suppressMessages(md_build_groups(con))
  expect_identical(groups(con), first)

  # a new family with smaller EINs, which would renumber a row-number id
  DBI::dbAppendTable(con, "ein_relation", edges(e(1), e(2)))
  suppressMessages(md_build_groups(con))
  after <- groups(con)
  keep <- after$ein %in% first$ein
  expect_identical(after$group_id[keep], first$group_id)
})

test_that("an empty edge set builds an empty table", {
  skip_if_not_installed("duckdb")
  con <- rel_db(edges(e(1), e(2), "related_entity"))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  out <- suppressMessages(md_build_groups(con))
  expect_equal(out$groups, 0)
  expect_equal(nrow(groups(con)), 0)
})

# --- evidence ranking: a self-reported edge must not join two families --------

ev_db <- function(rows) {
  con <- DBI::dbConnect(duckdb::duckdb())
  DBI::dbExecute(con, "CREATE TABLE ein_relation (ein_a VARCHAR, ein_b VARCHAR,
    relation VARCHAR, evidence VARCHAR, n_obs INTEGER, last_year INTEGER)")
  DBI::dbAppendTable(con, "ein_relation", rows)
  con
}
ev <- function(a, b, evidence, n_obs = NA, last_year = NA) {
  data.frame(ein_a = a, ein_b = b, relation = "group_member", evidence = evidence,
             n_obs = as.integer(n_obs), last_year = as.integer(last_year),
             stringsAsFactors = FALSE)
}

test_that("a member's own H(c) report does not override its BMF parent", {
  skip_if_not_installed("duckdb")
  # e(3) is coded under e(1) by the BMF, and wrote e(10)'s GEN on its 990
  con <- ev_db(rbind(ev(e(1), e(c(2, 3)), "bmf_group_exemption"),
                     ev(e(10), e(11), "bmf_group_exemption"),
                     ev(e(10), e(3), "efile_group_exemption_number", 1, 2022)))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  out <- suppressMessages(md_build_groups(con))
  g <- groups(con)
  expect_equal(out$groups, 2)
  expect_equal(g$group_id[g$ein == e(3)], "GRP-00-0000001")
  expect_equal(g$n_parents[g$ein == e(3)], 1)
})

test_that("from self-reported evidence a member keeps its most-reported parent", {
  skip_if_not_installed("duckdb")
  # e(5) has no BMF parent; it reported e(1)'s GEN in 3 filings, e(10)'s in 1
  con <- ev_db(rbind(ev(e(1), e(2), "bmf_group_exemption"),
                     ev(e(10), e(11), "bmf_group_exemption"),
                     ev(e(1), e(5), "efile_group_exemption_number", 3, 2023),
                     ev(e(10), e(5), "efile_group_exemption_number", 1, 2025)))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  out <- suppressMessages(md_build_groups(con))
  g <- groups(con)
  expect_equal(out$groups, 2)
  expect_equal(g$group_id[g$ein == e(5)], g$group_id[g$ein == e(1)])
  expect_false(g$group_id[g$ein == e(5)] == g$group_id[g$ein == e(10)])
})

test_that("curated evidence is kept whole, so a real two-parent member still joins", {
  skip_if_not_installed("duckdb")
  # the parent's own roster places e(3) under e(10) as well as the BMF parent;
  # both are rank-1 or rank-2 evidence, so the families join
  con <- ev_db(rbind(ev(e(1), e(c(2, 3)), "bmf_group_exemption"),
                     ev(e(10), e(3), "bmf_group_exemption"),
                     ev(e(10), e(11), "efile_affiliate_listing", 1, 2015)))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  out <- suppressMessages(md_build_groups(con))
  expect_equal(out$groups, 1)
  expect_equal(groups(con)$n_parents[groups(con)$ein == e(3)], 2)
})

test_that("weaker edges are set aside, not deleted from ein_relation", {
  skip_if_not_installed("duckdb")
  con <- ev_db(rbind(ev(e(1), e(2), "bmf_group_exemption"),
                     ev(e(10), e(2), "nccs_group_metadata_historical")))
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_message(md_build_groups(con), "1 set aside")
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) n FROM ein_relation")$n, 2)
  expect_false(e(10) %in% groups(con)$ein)
})
