#!/usr/bin/env bash
# Tests for quiet-gradle.sh using a mock ./gradlew. No real Gradle, no network.
# Run:  bash ./quiet-gradle.tests.sh
# Fixtures live under .agent-logs/tests (git-ignored) and are removed afterwards.
# Not automated: Ctrl+C interruption (check by hand with a slow scenario).

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixtures="$here/.agent-logs/tests"
pass=0; fail=0

check() { # check <0|1 ok> <name>
  if [[ $1 == 1 ]]; then pass=$((pass + 1)); echo "  ok   $2"; else fail=$((fail + 1)); echo "  FAIL $2"; fi
}
has()  { [[ $1 == *"$2"* ]] && echo 1 || echo 0; }        # has <text> <literal>
hasre(){ [[ $1 =~ $2 ]] && echo 1 || echo 0; }            # hasre <text> <regex>
eq()   { [[ $1 == "$2" ]] && echo 1 || echo 0; }

write_mock() { # write_mock <dir>
  cat > "$1/gradlew" <<'MOCK'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
{ echo "cwd=$(pwd)"; for a in "$@"; do echo "arg=[$a]"; done; } > "$here/record.txt"
case "${MOCK_SCENARIO:-}" in
  pass)    for i in $(seq 1 200); do echo "> Task :app:task$i UP-TO-DATE"; done; echo 'BUILD SUCCESSFUL in 3s'; exit 0 ;;
  warn)    echo 'w: file:///a/A.kt:1:1 Deprecated thing'; echo 'w: file:///a/A.kt:1:1 Deprecated thing'; echo 'A.java:3: warning: [deprecation] x'; echo '> Task :app:ok'; exit 0 ;;
  kotlin)  echo '> Task :app:compileDebugKotlin FAILED'; echo 'e: file:///C:/x/Main.kt:42:5 Unresolved reference: value'; echo 'FAILURE: Build failed with an exception.'; echo '* What went wrong:'; echo "Execution failed for task ':app:compileDebugKotlin'."; echo 'BUILD FAILED in 2s'; exit 1 ;;
  java)    echo '> Task :app:compileDebugJavaWithJavac FAILED'; echo '/x/Foo.java:12: error: cannot find symbol'; echo '  symbol: variable bar'; echo 'BUILD FAILED in 2s'; exit 1 ;;
  test)    echo 'com.example.SomeTest > testFoo FAILED'; echo '    java.lang.AssertionError at SomeTest.kt:9'; echo 'There were failing tests. See the report at: file:///x/build/reports/tests/index.html'; echo 'BUILD FAILED in 2s'; exit 1 ;;
  dep)     echo '* What went wrong:'; echo 'Could not resolve all files for configuration'; echo '> Could not resolve com.example:lib:1.0.'; echo '   > Could not find com.example:lib:1.0.'; echo 'BUILD FAILED in 2s'; exit 1 ;;
  generic) echo 'something odd happened'; echo 'and then it stopped'; exit 3 ;;
  large)   seq 1 30000 | sed 's/^/> Task :app:noise/'; echo 'e: file:///x/Big.kt:7:1 Mid-log error'; seq 30001 60000 | sed 's/^/> Task :app:more/'; echo 'BUILD FAILED in 9s'; exit 1 ;;
  unicode) printf 'h\xc3\xa9llo \xe2\x9c\x93 \xe6\x97\xa5\xe6\x9c\xac\n'; exit 0 ;;
  mixed)   echo out1; echo err1 >&2; echo out2; exit 0 ;;
  slow)    sleep 1.5; echo 'slow done'; exit 0 ;;
  exit7)   echo nope; exit 7 ;;
  daemon)  # lingering child like a Gradle daemon: detached, own stdio, holds only leaked fds
           setsid sleep 25 </dev/null >/dev/null 2>&1 &
           echo 'BUILD SUCCESSFUL'; exit 0 ;;
  *)       echo 'no scenario'; exit 0 ;;
esac
MOCK
  chmod +x "$1/gradlew"
}

new_fixture() { # new_fixture <name> [nogradle]
  local d="$fixtures/$1 with spaces"
  rm -rf -- "$d"; mkdir -p -- "$d"
  cp "$here/quiet-gradle.sh" "$d/"; chmod +x "$d/quiet-gradle.sh"
  [[ ${2-} == nogradle ]] || write_mock "$d"
  FX="$d"
}

run_qg() { # run_qg <dir> <scenario> [args...]  -> OUT CODE LOG NLINES LOGS
  local d=$1 scen=$2; shift 2
  OUT="$(cd / && MOCK_SCENARIO=$scen bash "$d/quiet-gradle.sh" "$@")"; CODE=$?
  NLINES=$(printf '%s' "$OUT" | grep -c '')
  LOGS=(); [[ -d $d/.agent-logs/gradle ]] && mapfile -t LOGS < <(ls -1 "$d/.agent-logs/gradle"/*.log 2>/dev/null | sort)
  LOG=""; ((${#LOGS[@]})) && LOG="$(cat "${LOGS[-1]}")"
}

trap 'rm -rf -- "$fixtures"' EXIT
mkdir -p "$fixtures"

echo 'success, noisy'
new_fixture pass; d=$FX; run_qg "$d" pass assembleDebug
check "$(eq "$CODE" 0)" 'exit 0'
check "$(eq "$NLINES" 2)" 'only RUN and PASS lines'
check "$(hasre "$OUT" 'QG PASS assembleDebug +exit=0')" 'PASS line'
check "$([[ $OUT != *UP-TO-DATE* ]] && echo 1 || echo 0)" 'no routine task output'
check "$(has "$LOG" 'Task :app:task200 UP-TO-DATE')" 'log holds hidden output'

echo 'runs adjacent gradlew from another directory'
rec="$(cat "$d/record.txt")"
check "$(has "$rec" "cwd=$d")" 'working dir is project root'
check "$(has "$rec" 'arg=[--console=plain]')" '--console=plain added'
run_qg "$d" pass --console=rich assembleDebug
check "$([[ $(cat "$d/record.txt") != *'arg=[--console=plain]'* ]] && echo 1 || echo 0)" 'caller console option respected'

echo 'warnings'
new_fixture warn; d=$FX; run_qg "$d" warn assembleDebug
check "$([[ $OUT != *Deprecated* ]] && echo 1 || echo 0)" 'hidden by default'
run_qg "$d" warn -ShowWarnings assembleDebug
check "$(eq "$(grep -c 'Deprecated thing' <<<"$OUT")" 1)" 'deduplicated'
check "$(has "$OUT" '[deprecation]')" 'javac warning shown'
check "$(has "$OUT" 'QG PASS')" 'PASS follows warnings'

echo 'failures'
new_fixture kotlin; d=$FX; run_qg "$d" kotlin assembleDebug
check "$(eq "$CODE" 1)" 'exit 1 preserved'
check "$(has "$OUT" 'Main.kt:42:5 Unresolved reference: value')" 'kotlin error shown'
check "$(has "$OUT" "${LOGS[-1]}")" 'absolute log path printed'
new_fixture java; d=$FX; run_qg "$d" java assembleDebug
check "$(has "$OUT" 'Foo.java:12: error: cannot find symbol')" 'java error shown'
new_fixture test; d=$FX; run_qg "$d" test testDebugUnitTest
check "$([[ $OUT == *'SomeTest > testFoo FAILED'* && $OUT == *'reports/tests/index.html'* ]] && echo 1 || echo 0)" 'test failure and report path'
new_fixture dep; d=$FX; run_qg "$d" dep assembleDebug
check "$([[ $OUT == *'Could not resolve com.example:lib'* && $OUT == *'Could not find'* ]] && echo 1 || echo 0)" 'dependency failure block'
new_fixture generic; d=$FX; run_qg "$d" generic assembleDebug
check "$(eq "$CODE" 3)" 'exit 3 preserved'
check "$([[ $OUT == *'no specific diagnostic block detected'* && $OUT == *'and then it stopped'* ]] && echo 1 || echo 0)" 'bounded tail fallback'
new_fixture exit7; d=$FX; run_qg "$d" exit7 x
check "$(eq "$CODE" 7)" 'exit 7 preserved'

echo 'large output and limits'
new_fixture large; d=$FX
s=$SECONDS; run_qg "$d" large assembleDebug; el=$((SECONDS - s))
check "$(eq "$CODE" 1)" 'exit 1'
check "$((NLINES <= 215 ? 1 : 0))" "console bounded ($NLINES lines)"
check "$(has "$OUT" 'Big.kt:7:1 Mid-log error')" 'mid-log error found'
check "$(( $(printf '%s\n' "$LOG" | wc -l) > 60000 ? 1 : 0 ))" 'log has everything'
echo "       (60k-line run took ${el}s)"
run_qg "$d" large -TailLines 5 -MaxSummaryLines 10 assembleDebug
check "$((NLINES <= 20 ? 1 : 0))" "custom limits ($NLINES lines)"

echo 'arguments'
new_fixture args; d=$FX
run_qg "$d" pass testDebugUnitTest --tests 'com.example.Some Test' '-Pfoo=bar baz' -Dx.y=1 -s -t -m -q -f
rec="$(cat "$d/record.txt")"
check "$(has "$rec" 'arg=[com.example.Some Test]')" 'spaced test filter intact'
check "$(has "$rec" 'arg=[-Pfoo=bar baz]')" 'spaced -P property intact'
check "$(has "$rec" 'arg=[-Dx.y=1]')" '-D property intact'
check "$([[ $rec == *'arg=[-s]'* && $rec == *'arg=[-t]'* && $rec == *'arg=[-m]'* && $rec == *'arg=[-f]'* ]] && echo 1 || echo 0)" 'short flags not stolen'

echo 'unicode and stream mixing'
new_fixture uni; d=$FX; run_qg "$d" unicode x
check "$(has "$LOG" $'h\xc3\xa9llo \xe2\x9c\x93 \xe6\x97\xa5\xe6\x9c\xac')" 'unicode preserved in log'
new_fixture mix; d=$FX; run_qg "$d" mixed x
check "$([[ $LOG == *out1* && $LOG == *err1* && $LOG == *out2* ]] && echo 1 || echo 0)" 'stdout and stderr both logged'

echo '-Full'
new_fixture full; d=$FX; run_qg "$d" pass -Full assembleDebug
check "$(has "$OUT" 'Task :app:task200 UP-TO-DATE')" 'output streamed'
check "$(has "$OUT" 'BUILD SUCCESSFUL in 3s')" 'last line not lost'
run_qg "$d" kotlin -Full assembleDebug
check "$([[ $OUT != *'relevant Gradle output'* && $OUT == *'Full log:'* ]] && echo 1 || echo 0)" 'no duplicate summary on failure'

echo 'parallel'
new_fixture par; d=$FX
( cd / && MOCK_SCENARIO=slow bash "$d/quiet-gradle.sh" x >/dev/null ) &
( cd / && MOCK_SCENARIO=slow bash "$d/quiet-gradle.sh" x >/dev/null ) &
wait
mapfile -t plogs < <(ls -1 "$d/.agent-logs/gradle"/*.log)
check "$(eq "${#plogs[@]}" 2)" 'two distinct logs'
n=0; for f in "${plogs[@]}"; do grep -q 'slow done' "$f" && n=$((n + 1)); done
check "$(eq "$n" 2)" 'both logs complete'

echo 'lingering daemon must not hold a leaked caller fd'
new_fixture daemon; d=$FX
s=$SECONDS
res="$(cd / && MOCK_SCENARIO=daemon bash "$d/quiet-gradle.sh" assembleDebug 3>&1)"
el=$((SECONDS - s))
check "$((el < 15 ? 1 : 0))" "caller sees EOF while a child lingers (25s child, took ${el}s)"
check "$(has "$res" 'QG PASS')" 'PASS reported'

echo 'wrapper errors'
new_fixture nogradle nogradle; d=$FX; run_qg "$d" pass x
check "$([[ $CODE == 70 && $OUT == *'gradlew not found'* ]] && echo 1 || echo 0)" 'missing gradlew -> 70'
check "$([[ ! -e $d/.agent-logs ]] && echo 1 || echo 0)" 'no log dir created'
new_fixture badlog; d=$FX; echo x > "$d/blocker"; run_qg "$d" pass -LogDirectory blocker/sub x
check "$([[ $CODE == 70 && $OUT == *'cannot create log'* ]] && echo 1 || echo 0)" 'unwritable log dir -> 70'
check "$([[ ! -e $d/record.txt ]] && echo 1 || echo 0)" 'gradle never ran'
new_fixture noargs; d=$FX; run_qg "$d" pass
check "$([[ $CODE == 64 && $OUT == *'QG USAGE'* ]] && echo 1 || echo 0)" 'no arguments -> 64'
run_qg "$d" pass -TailLines abc x
check "$(eq "$CODE" 64)" 'bad -TailLines -> 64'
new_fixture notexec; d=$FX; chmod -x "$d/gradlew"; run_qg "$d" pass x
check "$([[ $CODE == 70 && $OUT == *'not executable'* ]] && echo 1 || echo 0)" 'non-executable gradlew -> 70'

echo 'pruning'
new_fixture prune; d=$FX; ld="$d/.agent-logs/gradle"; mkdir -p "$ld"
for i in $(seq 1 25); do printf 'old' > "$ld/$(printf '20200101-0000%02d.000-p1-%08x.log' "$i" "$i")"; done
echo x > "$ld/keep-me.txt"; echo x > "$ld/notes.log"; mkdir "$ld/20200101-000000.000-p1-deadbeef.log"
run_qg "$d" pass -KeepLogs 5 x
strict=0; for f in "$ld"/*.log; do b=${f##*/}; [[ -f $f && $b =~ ^[0-9]{8}-[0-9]{6}\.[0-9]{3}-p[0-9]+-[0-9a-f]{8}\.log$ ]] && strict=$((strict + 1)); done
check "$(eq "$strict" 5)" "5 wrapper logs kept ($strict)"
check "$([[ -f $ld/keep-me.txt && -f $ld/notes.log ]] && echo 1 || echo 0)" 'foreign files untouched'
check "$([[ -d $ld/20200101-000000.000-p1-deadbeef.log ]] && echo 1 || echo 0)" 'directory untouched'
run_qg "$d" pass -KeepLogs 0 x; run_qg "$d" pass -KeepLogs 0 x
strict=0; for f in "$ld"/*.log; do b=${f##*/}; [[ -f $f && $b =~ ^[0-9]{8}- ]] && strict=$((strict + 1)); done
check "$((strict >= 7 ? 1 : 0))" '-KeepLogs 0 disables pruning'

echo
echo "passed=$pass failed=$fail"
exit $((fail > 0 ? 1 : 0))
