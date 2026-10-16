#!/bin/sh
# report-failures.sh LOG STATUS: a test run's totals, and what failed, as annotations on the run's summary page
# (readable through the public API, unlike the job's log): the failed tests, the golden programs
# that failed, and the first panics with what they printed
log=${1:-test.log}
[ -f "$log" ] || exit 0
# an annotation, through printf: macOS's sh is bash in POSIX mode, whose echo reads \n and \c in
# a panic's text as escapes and cuts the command short
note() { printf '::%s title=%s::%s\n' "$1" "$2" "$3"; }
# every run: how many tests passed, failed and were ignored in all, to compare systems (a system
# that skips more than Linux does shows it here)
total() { grep -aoE "[0-9]+ $1" "$log" | awk '{ n += $1 } END { print n + 0 }'; }
note notice tests "$(total passed) passed, $(total failed) failed, $(total ignored) ignored"
[ "${2:-failure}" = success ] && exit 0
# tests cargo said had been running for over 60 seconds and that never reported: where a job killed at
# its time limit was stuck (listed whatever the status, since a cancelled job's status isn't failure)
hung=$(grep -aoE '^test [^ ]+ has been running for over 60 seconds' "$log" | awk '{ print $2 }' | sort -u | while read -r t; do
    grep -aqE "^test $t \.\.\. (ok|FAILED|ignored)" "$log" || printf '%s\n' "$t"
done | paste -sd ' ' -)
[ -n "$hung" ] && note error "still running" "$hung"
# lines joined as one annotation (awk: macOS's sed has no GNU :a;N loop)
oneline() { awk 'BEGIN { ORS = "%0A" } { gsub(/%/, "%25"); gsub(/\r/, ""); print }'; }
tests=$(grep -aE '^test .* \.\.\. FAILED$' "$log" | sed 's/^test //; s/ \.\.\. FAILED$//' | head -40 | paste -sd ' ' -)
[ -n "$tests" ] && note error "failed tests" "$tests"
golden=$(grep -aE '^[A-Za-z]?:?[/\\].*\.volt: (exit|want errors)' "$log" | head -40 | oneline)
[ -n "$golden" ] && note error "failed programs" "$golden"
# the panics, each up to the next test's output and cut to 900 bytes, packed into errors of up to the
# 4 KB an annotation holds (GitHub keeps 10 errors and 10 warnings a step: these take up to 6)
grep -an 'panicked at' "$log" | head -30 | {
    acc=
    sent=0
    flush() {
        [ -n "$acc" ] && [ "$sent" -lt 6 ] && note error panics "$(printf '%s' "$acc" | oneline)"
        sent=$((sent + 1))
        acc=
    }
    while IFS=: read -r n _; do
        body=$(sed -n "${n},$((n + 300))p" "$log" | awk 'NR > 1 && (/^---- .* stdout ----$/ || /^failures:$/) { exit } { print }' | cut -c1-200 | head -c 900)
        [ -n "$acc" ] && [ $((${#acc} + ${#body})) -gt 3700 ] && flush
        acc="$acc$body
"
    done
    flush
}
# each failed golden program on its own (its want, got and stderr), as warnings
awk '/^[A-Za-z]?:?[\/\\].*\.volt: (exit|want errors)/ { if (n++ < 10) { f = "golden." n } else { f = "" } } /^thread / { f = "" } f { print > f }' "$log" 2>/dev/null
for g in golden.*; do
    [ -f "$g" ] || continue
    note warning "$(head -1 "$g" | sed 's|.*/||; s/:.*//')" "$(cut -c1-300 "$g" | head -c 3800 | oneline)"
    rm -f "$g"
done
# a build or harness error with no test line (a crate that didn't compile, a missing tool)
if [ -z "$tests" ]; then
    note error "log tail" "$(grep -av '^\s*$' "$log" | tail -30 | cut -c1-400 | oneline)"
fi
exit 0
