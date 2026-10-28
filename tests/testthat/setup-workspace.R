# Every test runs against a throwaway data root, so nothing it logs or fetches
# lands in the real one. Tests that need their own root still set MATCHDB_DATA.
withr::local_envvar(MATCHDB_DATA = tempfile("matchdb-test-root"), .local_envir = teardown_env())
