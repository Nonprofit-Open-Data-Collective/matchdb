#' The canonical EIN format
#'
#' Every key in matchdb is an **EIN2** - `EIN-XX-XXXXXXX`, e.g.
#' `EIN-00-0019818`. This is the stable identifier used across the e-file data
#' series, the BMF, and the NCCS metadata crosswalks, and matchdb adopts it so
#' joins across those sources need no conversion step in which a leading zero can
#' be lost.
#'
#' Leading zeros are the whole reason for the format. `00-0019818` read as a
#' number is `19818`, and an EIN column that has passed through a spreadsheet or
#' an untyped CSV read is a well known way to lose organisations whose EIN begins
#' with zero. A string that cannot be coerced to a number cannot be silently
#' renumbered.
#'
#' Semantics follow `ef2::format_ein()`, which is the upstream definition, with
#' one deliberate difference described below. matchdb does not depend on ef2 -
#' it is an ETL pipeline rather than a library - so the function is reimplemented
#' in base R and tested against ef2's documented examples.
#'
#' @section Strictness:
#' `ef2::format_ein()` strips non-digits and pads to nine characters, then takes
#' `substr(x, 1, 2)` and `substr(x, 3, 9)`. An input carrying more than nine
#' digits is therefore **silently truncated**: `"12345678901"` becomes
#' `"EIN-12-3456789"`, with the trailing digits discarded and no warning.
#'
#' For a provenance database that is the wrong default - a mangled identifier
#' attaches a real organisation's rows to a different EIN, and nothing downstream
#' can detect it. `md_ein()` therefore returns `NA` for any input that is not
#' exactly nine digits once punctuation is removed, and warns with a count. Pass
#' `strict = FALSE` for ef2's truncating behaviour.
#'
#' @param x Character or numeric vector of EINs in any mixed format -
#'   `"123456789"`, `"12-3456789"`, `"EIN-12-3456789"`, `"ein-12-3456789"`.
#' @param to `"id"` for `EIN-XX-XXXXXXX`, `"n"` for nine bare digits.
#' @param strict Return `NA` rather than truncating when the digit count is not
#'   nine. Defaults to `TRUE`.
#' @return A character vector, `NA` where the input could not be represented.
#' @examples
#' md_ein(c("123456789", "12-3456789", "EIN-12-3456789"))
#' md_ein("EIN-00-0019818", to = "n")
#' md_ein("19818")                       # padded: EIN-00-0019818
#' suppressWarnings(md_ein("12345678901"))  # NA, not silent truncation
#' @export
md_ein <- function(x, to = c("id", "n"), strict = TRUE) {
  to <- match.arg(to)
  x <- as.character(x)
  digits <- gsub("[^0-9]", "", x)

  blank <- is.na(x) | !nzchar(digits)
  # Pad short inputs; this is the leading-zero case the format exists for.
  # Note formatC(flag = "0") pads character input with spaces, not zeros.
  short <- !blank & nchar(digits) < 9L
  digits[short] <- paste0(strrep("0", 9L - nchar(digits[short])), digits[short])

  long <- !blank & nchar(digits) > 9L
  if (any(long)) {
    if (strict) {
      warning(sum(long), " EIN(s) had more than 9 digits and became NA; ",
              "pass strict = FALSE for ef2::format_ein()'s truncating behaviour",
              call. = FALSE)
    } else {
      digits[long] <- substr(digits[long], 1L, 9L)
    }
  }

  bad <- blank | (strict & long)
  out <- if (to == "id") {
    paste0("EIN-", substr(digits, 1L, 2L), "-", substr(digits, 3L, 9L))
  } else {
    digits
  }
  out[bad] <- NA_character_
  out
}

#' @rdname md_ein
#' @description `md_is_ein()` tests for the canonical form without converting.
#' @export
md_is_ein <- function(x) {
  !is.na(x) & grepl("^EIN-[0-9]{2}-[0-9]{7}$", x)
}
