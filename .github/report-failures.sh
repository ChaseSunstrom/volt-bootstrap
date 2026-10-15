#!/bin/sh
# report-failures.sh LOG: what failed in a test run's log, as annotations on the run's summary page
# (readable through the public API, unlike the job's log): the failed tests, the golden programs
# that failed, and the first panics with what they printed
log=${1:-test.log}
[ -f "$log" ] || exit 0
oneline() { sed ':a;N;$!ba;s/%/%25/g;s/\r//g;s/\n/%0A/g'; }
tests=$(grep -aE '^test .* \.\.\. FAILED$' "$log" | sed 's/^test //; s/ \.\.\. FAILED$//' | head -40 | paste -sd ' ' -)
[ -n "$tests" ] && echo "::error title=failed tests::$tests"
golden=$(grep -aE '^[A-Za-z]?:?[/\\].*\.volt: (exit|want errors)' "$log" | head -40 | oneline)
[ -n "$golden" ] && echo "::error title=failed programs::$golden"
grep -an 'panicked at' "$log" | head -7 | while IFS=: read -r n _; do
    echo "::error title=panic::$(sed -n "${n},$((n + 24))p" "$log" | cut -c1-400 | oneline)"
done
# a build or harness error with no test line (a crate that didn't compile, a missing tool)
if [ -z "$tests" ]; then
    echo "::error title=log tail::$(grep -av '^\s*$' "$log" | tail -30 | cut -c1-400 | oneline)"
fi
exit 0
