# Which normalizer built something, for stamps, pins and the workspace log.
#
# The normalizer is npnormalize's. npmatch is only suggested, so its version is
# NA when it is not installed; npnormalize's never is.

.md_pkg_version <- function(pkg) {
  tryCatch(as.character(utils::packageVersion(pkg)), error = function(e) NA_character_)
}

# The commit a package was installed from (remotes / pak / devtools), or NA.
.md_pkg_commit <- function(pkg) {
  d <- suppressWarnings(tryCatch(utils::packageDescription(pkg), error = function(e) NULL))
  if (!is.list(d)) return(NA_character_)
  d$RemoteSha %||% d$GithubSHA1 %||% NA_character_
}

.md_normalizer_versions <- function() {
  list(npnormalize_version = .md_pkg_version("npnormalize"),
       npmatch_version = .md_pkg_version("npmatch"),
       normalize_signature = npnormalize::np_normalize_signature())
}
