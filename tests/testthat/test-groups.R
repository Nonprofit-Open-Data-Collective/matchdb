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
