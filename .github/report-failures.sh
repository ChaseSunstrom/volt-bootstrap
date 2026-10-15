#!/bin/sh
# report-failures.sh LOG STATUS: a test run's totals, and what failed, as annotations on the run's summary page
# (readable through the public API, unlike the job's log): the failed tests, the golden programs
# that failed, and the first panics with what they printed
log=${1:-test.log}
[ -f "$log" ] || exit 0
# every run: how many tests passed, failed and were ignored in all, to compare systems (a system
# that skips more than Linux does shows it here)
total() { grep -aoE "[0-9]+ $1" "$log" | awk '{ n += $1 } END { print n + 0 }'; }
echo "::notice title=tests::$(total passed) passed, $(total failed) failed, $(total ignored) ignored"
[ "${2:-failure}" = success ] && exit 0
# lines joined as one annotation (awk: macOS's sed has no GNU :a;N loop)
oneline() { awk 'BEGIN { ORS = "%0A" } { gsub(/%/, "%25"); gsub(/\r/, ""); print }'; }
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
