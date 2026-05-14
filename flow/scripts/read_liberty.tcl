#Read Liberty (or LDB binary cache when USE_LDB is enabled)
set use_ldb [env_var_equals USE_LDB 1]
if { [env_var_exists_and_non_empty CORNERS] } {
  # corners
  define_corners {*}$::env(CORNERS)
  foreach corner $::env(CORNERS) {
    if { $use_ldb } {
      set LIBKEY "[string toupper $corner]_LDB_FILES"
      foreach ldbFile $::env($LIBKEY) {
        log_cmd read_ldb -corner $corner -ignore_source_check $ldbFile
      }
    } else {
      set LIBKEY "[string toupper $corner]_LIB_FILES"
      foreach libFile $::env($LIBKEY) {
        log_cmd read_liberty -corner $corner $libFile
      }
    }
    unset LIBKEY
  }
  unset corner
} else {
  ## no corner
  if { $use_ldb } {
    foreach ldbFile $::env(LDB_FILES) {
      log_cmd read_ldb -ignore_source_check $ldbFile
    }
  } else {
    foreach libFile $::env(LIB_FILES) {
      log_cmd read_liberty $libFile
    }
  }
}
unset use_ldb
