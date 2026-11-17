#!/bin/sh
# Check the mechanical half of the commit message rules: the parts a script can
# see. The prose rules -- why the change was made, one logical change per
# commit, no padding -- are still on the author, and no hook can read them.
#
# Called by the commit-msg hook with the path to the message file. Exit 1 on a
# violation; a subject between the soft and hard limits is a warning, not a
# failure, because the rules call those soft.
#
# The shape is policy, so it comes from `:commit-message' in ci/config.el, and
# a project overrides the keys that differ in config/ci.el. The values below are
# the fallback for the rare checkout where config-export.sh cannot run; they
# match ci/config.el. The prose style file some projects keep (for pi,
# `.pi/ai-git-commit.json') is read by the editor, never by this script.
set -eu

msg=${1:-}
[ -n "$msg" ] && [ -f "$msg" ] || {
  echo "usage: $0 <commit-message-file>" >&2
  exit 2
}

here=$(cd "$(dirname "$0")" && pwd)

# Defaults, overridden below.
capitalize=1
forbid_prefix=1
forbid_period=1
soft_subject=60
max_subject=80
max_body=72
forbid_lines=$(cat <<'EOF'
This commit fixes
I changed
This PR
Generated with
Co-authored-by
EOF
)
warn_words=$(cat <<'EOF'
improve
enhance
robust
seamless
comprehensive
leverage
utilize
EOF
)

# One KEY=VALUE per line; list knobs repeat their key once per item. An empty
# export (no config-export.sh) leaves every default in place.
style=$("$here/config-export.sh" commit-message 2>/dev/null || true)
if [ -n "$style" ]; then
  forbid_lines=""
  warn_words=""
  while IFS='=' read -r key value; do
    case $key in
      capitalize) capitalize=$value ;;
      forbid_prefix) forbid_prefix=$value ;;
      forbid_period) forbid_period=$value ;;
      subject_soft) soft_subject=$value ;;
      subject_hard) max_subject=$value ;;
      body_width) max_body=$value ;;
      forbid_line) forbid_lines="${forbid_lines}${value}
" ;;
      warn_word) warn_words="${warn_words}${value}
" ;;
    esac
  done <<EOF
$style
EOF
fi

fail=0

problem() {
  echo "commit message: $1" >&2
  fail=1
}

# Drop the comment lines git would strip, so a template's own text is not read
# as part of the message.
body=$(sed -e '/^#/d' -e '/^# ------------------------ >8/q' "$msg")
subject=$(printf '%s\n' "$body" | sed -n '1p')

[ -n "$subject" ] || problem "no subject line"

# Subject: capital, imperative-looking, no prefix, no trailing period.
if [ "$capitalize" -eq 1 ]; then
  case $subject in
    [ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) ;;
    *) problem "subject does not start with a capital letter" ;;
  esac
fi
if [ "$forbid_period" -eq 1 ]; then
  case $subject in
    *.) problem "subject ends with a period" ;;
  esac
fi
if [ "$forbid_prefix" -eq 1 ]; then
  case $subject in
    *:*)
      prefix=${subject%%:*}
      case $prefix in
        *\ *) ;;
        *) problem "subject starts with a '$prefix:' style prefix" ;;
      esac
      ;;
  esac
fi

# Widths are counted in bytes, one locale for everyone: a typographic dash
# then costs three columns instead of one, which errs on the narrow side and
# keeps the hook's answer identical on every machine.
len=$(printf '%s' "$subject" | LC_ALL=C wc -c | tr -d ' ')
[ "$len" -le "$max_subject" ] || problem "subject is $len columns, hard limit is $max_subject"
if [ "$len" -gt "$soft_subject" ]; then
  echo "commit message: subject is $len columns, past the soft limit of $soft_subject" >&2
fi

# Body: lines within the configured width. A line with no space in it is a URL
# or a path, and those are allowed to run long.
n=0
while IFS= read -r text; do
  n=$((n + 1))
  [ "$n" -gt 2 ] || continue
  w=$(printf '%s' "$text" | LC_ALL=C wc -c | tr -d ' ')
  [ "$w" -gt "$max_body" ] || continue
  case $text in *" "*) ;; *) continue ;; esac
  case $text in *http://*|*https://*) continue ;; esac
  echo "commit message: body line $n is $w columns, limit is $max_body" >&2
  echo "  $(printf '%s' "$text" | cut -c1-60)" >&2
  fail=1
done <<EOF
$body
EOF

# These are forbidden as statements and as trailers, which is how they are
# written; a message that discusses the rule may name it mid-sentence.
while IFS= read -r phrase; do
  [ -n "$phrase" ] || continue
  if printf '%s\n' "$body" | grep -qi "^[[:space:]]*$phrase" 2>/dev/null; then
    problem "opens a line with '$phrase'"
  fi
done <<EOF
$forbid_lines
EOF

# The word list warns rather than fails. It catches the case the rules care
# about, a change described with a word that proves nothing, and it also
# catches ordinary prose that happens to use one of them -- a message about a
# reader improving their odds is not marketing. A false failure in a gate is
# worse than a warning a person reads.
while IFS= read -r word; do
  [ -n "$word" ] || continue
  if printf '%s\n' "$body" | grep -Fqiw "$word"; then
    echo "commit message: '$word' is on the marketing word list; check that it proves something" >&2
  fi
done <<EOF
$warn_words
EOF

if printf '%s\n' "$body" | LC_ALL=C grep -q '[^ -~\t]'; then
  echo "commit message: non-ASCII characters; typographic dashes are fine, emoji are not" >&2
fi

exit "$fail"
