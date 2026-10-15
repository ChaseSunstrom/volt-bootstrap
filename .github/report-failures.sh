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
# each panic up to the next test's output, cut to the 4 KB an annotation holds (GitHub keeps 10
# errors and 10 warnings a step: these take 6 of the errors)
grep -an 'panicked at' "$log" | head -6 | while IFS=: read -r n _; do
    body=$(sed -n "${n},$((n + 300))p" "$log" | awk 'NR > 1 && (/^---- .* stdout ----$/ || /^failures:$/) { exit } { print }' | cut -c1-300 | head -c 3800)
    echo "::error title=panic::$(printf '%s\n' "$body" | oneline)"
done
# each failed golden program on its own (its want, got and stderr), as warnings
awk '/^[A-Za-z]?:?[\/\\].*\.volt: (exit|want errors)/ { if (n++ < 10) { f = "golden." n } else { f = "" } } /^thread / { f = "" } f { print > f }' "$log" 2>/dev/null
for g in golden.*; do
    [ -f "$g" ] || continue
    echo "::warning title=$(head -1 "$g" | sed 's|.*/||; s/:.*//')::$(cut -c1-300 "$g" | head -c 3800 | oneline)"
    rm -f "$g"
done
# a build or harness error with no test line (a crate that didn't compile, a missing tool)
if [ -z "$tests" ]; then
    echo "::error title=log tail::$(grep -av '^\s*$' "$log" | tail -30 | cut -c1-400 | oneline)"
fi
exit 0
