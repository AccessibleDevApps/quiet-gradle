#!/usr/bin/env bash
# quiet-gradle.sh - run this project's ./gradlew with bounded console output.
#
# Full Gradle output always goes to a project-local log. The console gets one
# RUN line, then one PASS line, or a bounded failure excerpt plus the log path.
#
# Usage:  ./quiet-gradle.sh [wrapper options] <gradle tasks and arguments>
#
# Wrapper options (only recognised BEFORE the first Gradle argument, exact names,
# same names as quiet-gradle.ps1 so agent instructions work on both):
#   -Full                 stream Gradle output to the console (log is still saved)
#   -ShowWarnings         on success, print a bounded, deduplicated warning list
#   -TailLines N          trailing log lines kept in a failure excerpt (80)
#   -MaxSummaryLines N    hard cap on log lines printed after a failure (200)
#   -LogDirectory PATH    log directory (default .agent-logs/gradle, relative to script)
#   -KeepLogs N           keep newest N wrapper logs, prune older; 0 = never prune (20)
#
# Exit codes: Gradle's own code for Gradle outcomes.
#             64 = usage/invocation error, 70 = wrapper error (no gradlew, cannot
#             write log), 130 = interrupted.
#
# Needs bash 4+, GNU date/tail, awk (mawk or gawk), Linux. Runs only ./gradlew beside
# this script; never searches elsewhere and never falls back to a system gradle.

set -u

EXIT_USAGE=64
EXIT_INTERNAL=70
MAX_LINE_CHARS=400

say() { printf '%s\n' "$*"; }

# ---- wrapper option parsing (leading options only) ---------------------------
full=0; show_warnings=0
tail_lines=80; max_summary=200; keep_logs=20
log_dir_opt=".agent-logs/gradle"

need_int() {
  if [[ ! "${2-}" =~ ^[0-9]+$ ]]; then
    say "QG ERROR $1 needs a non-negative integer."
    exit $EXIT_USAGE
  fi
}

while (($#)); do
  case "$1" in
    -Full)            full=1; shift ;;
    -ShowWarnings)    show_warnings=1; shift ;;
    -TailLines)       need_int -TailLines "${2-}";       tail_lines=$((10#$2));  shift 2 ;;
    -MaxSummaryLines) need_int -MaxSummaryLines "${2-}"; max_summary=$((10#$2)); shift 2 ;;
    -KeepLogs)        need_int -KeepLogs "${2-}";        keep_logs=$((10#$2));   shift 2 ;;
    -LogDirectory)
      if (($# < 2)); then say 'QG ERROR -LogDirectory needs a path.'; exit $EXIT_USAGE; fi
      log_dir_opt=$2; shift 2 ;;
    *) break ;;
  esac
done
gargs=("$@")

if ((${#gargs[@]} == 0)); then
  say 'QG USAGE  ./quiet-gradle.sh [-Full] [-ShowWarnings] [-TailLines N] [-MaxSummaryLines N]'
  say '                            [-LogDirectory PATH] [-KeepLogs N] <gradle tasks and arguments>'
  exit $EXIT_USAGE
fi

# ---- locate gradlew (beside this script only) ---------------------------------
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
gradle="$root/gradlew"
if [[ ! -f $gradle ]]; then
  say "QG ERROR gradlew not found beside the script: $gradle"
  exit $EXIT_INTERNAL
fi
if [[ ! -x $gradle ]]; then
  say "QG ERROR gradlew is not executable (chmod +x gradlew): $gradle"
  exit $EXIT_INTERNAL
fi

has_console=0
for a in "${gargs[@]}"; do
  if [[ $a == --console || $a == --console=* ]]; then has_console=1; fi
done
label="${gargs[*]}"
if ((has_console == 0)); then gargs=(--console=plain "${gargs[@]}"); fi
if ((${#label} > 100)); then label="${label:0:97}..."; fi

# ---- create the unique log (fatal if it cannot be written) ---------------------
case "$log_dir_opt" in
  /*) log_dir=$log_dir_opt ;;
  *)  log_dir="$root/$log_dir_opt" ;;
esac
if ! mkdir -p -- "$log_dir" 2>/dev/null; then
  say "QG ERROR cannot create log directory '$log_dir'"
  exit $EXIT_INTERNAL
fi
stamp="$(date +%Y%m%d-%H%M%S.%3N)"
[[ $stamp =~ ^[0-9]{8}-[0-9]{6}\.[0-9]{3}$ ]] || stamp="$(date +%Y%m%d-%H%M%S).000"
suffix="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
log="$log_dir/$stamp-p$$-$suffix.log"
if ! ( set -C; : >"$log" ) 2>/dev/null; then
  say "QG ERROR cannot create log in '$log_dir'"
  exit $EXIT_INTERNAL
fi
log_shown=$log
[[ $log == "$root"/* ]] && log_shown=${log#"$root"/}

say "QG RUN  $label  log=$log_shown"

# ---- run gradlew; the OS writes stdout+stderr to the log in arrival order ----------
# The child gets the log as stdout/stderr and /dev/null as stdin, and every other
# inherited fd is closed first, so a Gradle daemon that outlives this script cannot
# keep the caller's pipes open.
start_gradle() {
  (
    for f in /proc/$BASHPID/fd/*; do
      n=${f##*/}
      [[ $n =~ ^[0-9]+$ ]] && ((n > 2)) && eval "exec $n>&-"
    done
    exec "$gradle" "${gargs[@]}"
  ) >>"$log" 2>&1 </dev/null &
  gpid=$!
}

interrupted=0; gpid=""; tpid=""
trap 'interrupted=1; [[ -n $gpid ]] && kill -TERM "$gpid" 2>/dev/null' INT TERM

t0="$(date +%s.%N)"
start_gradle
if ((full)); then
  tail -n +1 -f --pid="$gpid" -- "$log" &
  tpid=$!
fi
wait "$gpid"; code=$?
if ((interrupted)); then wait "$gpid" 2>/dev/null; fi
[[ -n $tpid ]] && wait "$tpid" 2>/dev/null
t1="$(date +%s.%N)"
trap - INT TERM
duration="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1fs", b - a }')"

if ((interrupted)); then
  say "QG FAIL $label  interrupted  duration=$duration"
  say "Full log: $log"
  exit 130
fi

# ---- summaries -----------------------------------------------------------------------
failure_summary() {
  awk -v tailn="$tail_lines" -v cap="$max_summary" -v maxc="$MAX_LINE_CHARS" '
    function trunc(s) { return (length(s) > maxc) ? substr(s, 1, maxc) " ...[truncated]" : s }
    { lines[NR] = $0 }
    END {
      n = NR; nr = 0
      rx[++nr] = "what went wrong:";                                   bf[nr] = 0; af[nr] = 6
      rx[++nr] = "failure:";                                           bf[nr] = 0; af[nr] = 2
      rx[++nr] = "(^|[^a-z0-9_])failed($|[^a-z0-9_])";                 bf[nr] = 1; af[nr] = 3
      rx[++nr] = "execution failed for task";                          bf[nr] = 0; af[nr] = 3
      rx[++nr] = "caused by:";                                         bf[nr] = 0; af[nr] = 1
      rx[++nr] = "^e: ";                                               bf[nr] = 0; af[nr] = 1
      rx[++nr] = "error:";                                             bf[nr] = 0; af[nr] = 3
      rx[++nr] = "there were failing tests";                           bf[nr] = 1; af[nr] = 2
      rx[++nr] = "see the report at";                                  bf[nr] = 1; af[nr] = 1
      rx[++nr] = "could not (resolve|find|get)";                       bf[nr] = 0; af[nr] = 4
      used = 0
      tn = (tailn < cap) ? tailn : cap; if (tn > n) tn = n
      for (j = n - tn + 1; j <= n; j++) { keep[j] = 1; used++ }
      matched = 0; omitted = 0
      for (j = 1; j <= n; j++) {
        l = tolower(lines[j])
        for (r = 1; r <= nr; r++) {
          if (l !~ rx[r]) continue
          matched = 1
          from = j - bf[r]; if (from < 1) from = 1
          to = j + af[r];   if (to > n) to = n
          for (q = from; q <= to; q++) {
            if (q in keep) continue
            if (used >= cap) { omitted++; continue }
            keep[q] = 1; used++
          }
        }
      }
      if (matched) print "--- relevant Gradle output (bounded) ---"
      else print "--- no specific diagnostic block detected; showing log tail ---"
      gap = 0
      for (j = 1; j <= n; j++) {
        if (j in keep) { if (gap) { print "..."; gap = 0 } print trunc(lines[j]) }
        else if (j > 1 && ((j - 1) in keep)) gap = 1
      }
      if (omitted > 0) print "(" omitted " more matching lines omitted by -MaxSummaryLines; see full log)"
      print "--- end relevant output ---"
    }' "$log"
}

warning_summary() {
  awk -v cap="$max_summary" -v maxc="$MAX_LINE_CHARS" '
    function trunc(s) { return (length(s) > maxc) ? substr(s, 1, maxc) " ...[truncated]" : s }
    (/^w: / || tolower($0) ~ /warning:/ || /^WARNING/) && !($0 in seen) { seen[$0] = 1; list[++u] = $0 }
    END {
      if (u == 0) exit
      shown = (u < cap) ? u : cap
      print "--- warnings (" u " unique, showing " shown ") ---"
      for (j = 1; j <= shown; j++) print trunc(list[j])
      print "--- end warnings ---"
    }' "$log"
}

if ((code == 0)); then
  if ((show_warnings && !full)); then warning_summary || say "QG WARN could not summarise warnings"; fi
  say "QG PASS $label  exit=0  duration=$duration  log=$log_shown"
else
  say "QG FAIL $label  exit=$code  duration=$duration"
  if ((!full)); then
    failure_summary || { say "QG WARN summary failed; raw tail follows."; tail -n "$((tail_lines < max_summary ? tail_lines : max_summary))" -- "$log"; }
  fi
  say "Full log: $log"
fi

# ---- prune old wrapper logs (never affects the result) -----------------------------------
if ((keep_logs > 0)); then
  {
    mapfile -t mine < <(
      for f in "$log_dir"/*.log; do
        b=${f##*/}
        [[ -f $f && ! -L $f && $f != "$log" && $b =~ ^[0-9]{8}-[0-9]{6}\.[0-9]{3}-p[0-9]+-[0-9a-f]{8}\.log$ ]] && printf '%s\n' "$b"
      done | sort -r
    )
    for ((i = keep_logs - 1; i < ${#mine[@]}; i++)); do rm -f -- "$log_dir/${mine[i]}"; done
  } 2>/dev/null || say "QG WARN could not prune old logs"
fi

exit "$code"
