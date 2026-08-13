#!/system/bin/sh

# Match the exact installed daemon. Android may retain a running executable as
# " (deleted)" while a module update replaces its directory entry; in that
# case require argv[0] to still name the expected binary.
runtime_process_matches() {
  runtime_pid=$1
  runtime_expected=$2
  runtime_proc_root=${3:-/proc}
  case "$runtime_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -d "$runtime_proc_root/$runtime_pid" ] || return 1
  runtime_exe=$(readlink "$runtime_proc_root/$runtime_pid/exe" 2>/dev/null) || return 1
  case "$runtime_exe" in
    "$runtime_expected") return 0 ;;
    "$runtime_expected (deleted)")
      runtime_argv0=$(tr '\000' '\n' < "$runtime_proc_root/$runtime_pid/cmdline" 2>/dev/null | head -n 1)
      [ "$runtime_argv0" = "$runtime_expected" ]
      return
      ;;
  esac
  # KernelSU can keep a daemon from the previous module generation alive
  # while the current module path changes.  The executable is still the
  # installed daemon, but /proc/$pid/exe then resolves to the old generation
  # (or a staging path).  Accept that case only when both the resolved
  # executable basename and argv[0] identify the exact daemon name.
  runtime_name=${runtime_expected##*/}
  runtime_exe_name=${runtime_exe##*/}
  runtime_argv0=$(tr '\000' '\n' < "$runtime_proc_root/$runtime_pid/cmdline" 2>/dev/null | head -n 1)
  runtime_argv0_name=${runtime_argv0##*/}
  [ "$runtime_exe_name" = "$runtime_name" ] || return 1
  [ "$runtime_argv0_name" = "$runtime_name" ]
  return
}
