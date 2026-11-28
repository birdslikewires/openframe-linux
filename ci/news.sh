#!/bin/bash
# ci/news.sh [--upstream <file>] <path>...: the owners' notes for every version of a package whose version is year.month.N, N counting the month's commits that changed <path>s (as the version scripts that call this have it; openframe-linux and openframe-apps each have a copy, kept the same; openframe-scripts' package/version.sh and openframe-sprite's have the same within them), from the repository's root with its full history. Newest first, a line each: the version, a tab, the note. The notes are the "News:" lines of the commits that made each version; a commit may carry several, and most carry none. With --upstream, each version starts with what <file> (a shop.txt) said as version= at that commit, and a hyphen, as openframe-apps' versions do. of-update shows owners the notes between their version and the one offered (news/<package>.news beside the pool), and ci/testing-issue.sh shows those waiting in testing.
set -eu
up=""
[ "${1:-}" = --upstream ] && { up=$2; shift 2; }
TZ=UTC git log --reverse --format='%H %cd' --date=format-local:%y.%m -- "$@" |
	awk '{ n[$2]++; m = $2; sub(/\..*/, "", m); mm = substr($2, 4) + 0; print $1, m "." mm "." n[$2] }' |
	while read -r hash ver; do
		i=$((${i:-0} + 1))
		if [ -n "$up" ]; then
			u=$(git show "$hash:$up" 2>/dev/null | sed -n 's/^version=//p' | tail -1 | tr -d '[:space:]')
			ver="${u:+$u-}$ver"
		fi
		# Each "News:" line anywhere in the message, running on to a blank line, the next News: line or a trailer of ours, its lines joined (so a wrapped line starting "Settings: ..." stays in the note): not git's trailers alone, which only count in the message's last paragraph and fold only indented lines
		git log -1 --format=%B "$hash" | awk '
			function out() { if (n != "") print n; n = "" }
			/^News:/ { out(); n = $0; sub(/^News:[ \t]*/, "", n); next }
			n != "" && (/^[ \t]*$/ || /^(Co-Authored-By|Claude-Session|Signed-off-by):/) { out(); next }
			n != "" { l = $0; sub(/^[ \t]+/, "", l); n = n " " l }
			END { out() }' |
			awk -v i="$i" -v v="$ver" '{ print i "\t" NR "\t" v "\t" $0 }'
	done | sort -t "$(printf '\t')" -k1,1nr -k2,2n | cut -f3-
