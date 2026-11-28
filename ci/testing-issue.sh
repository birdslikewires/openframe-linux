#!/bin/bash
# testing-issue.sh: keeps the repository's "Waiting in testing" issue in step with the apt
# repository (ci/apt-suite.sh waiting), after a publish to the testing suite or a promotion.
# An issue, labelled testing and assigned to ASSIGNEE (the workflows give Andy's login: the
# repositories belong to an organisation, which can't be assigned), lists what test units
# have that other OpenFrames don't yet; each change is a comment on it, which GitHub sends to the
# assignee (the GitHub app, and email). "ok" or "no" as a reply on it starts promote.yml. Under
# the table, what's new in each package since the version every OpenFrame has, from
# news/<package>.news beside the pool (commits' News: lines), for whoever's testing.
# An issue holds one decision: once it's answered (ok or no, by ASSIGNEE), nothing more is added
# to it. Something published after the answer goes in a new issue, leaving out what an ok still
# being promoted covers; the promotion closes the answered issue, and opens a new one for
# anything left waiting with no issue of its own. Run from the repository's root, after
# apt-suite.sh, with GH_TOKEN (issues: write) and GITHUB_REPOSITORY.
#   testing-issue.sh "<what just happened, a sentence>"        after a publish
#   testing-issue.sh --answered <issue> "<what was promoted>"  after an ok promoted <issue>
set -eu
SITE=${APT_SITE:-linux.openbeak.net}
SUITE=${APT_SUITE_SCRIPT:-ci/apt-suite.sh}
R="$GITHUB_REPOSITORY"
answered=""
[ "${1:-}" = --answered ] && { answered=$2; shift 2; }

# The open testing issues, each with its answer: ok or no if ASSIGNEE has replied just that (as promote.yml takes it), else open
issues=$(gh issue list -R "$R" --label testing --state open --limit 50 --json number,comments \
	-q '.[] | [.number, ([.comments[] | select((env.ASSIGNEE // "") == "" or .author.login == env.ASSIGNEE) | (.body | ascii_downcase | gsub("^\\s+|\\s+$"; "")) | select(test("^(ok|no)[.!]?$")) | .[0:2]] | last // "open")] | @tsv')
# the one taking new things: the oldest unanswered
num=$(awk -F'\t' -v a="$answered" '$2 == "open" && $1 != a { print $1 }' <<< "$issues" | sort -n | head -1)

# What's waiting, but for what an ok still being promoted covers (the package and version its table lists)
pending=$(awk -F'\t' -v a="$answered" '$2 == "ok" && $1 != a { print $1 }' <<< "$issues" | while read -r n; do
	gh issue view "$n" -R "$R" --json body -q .body | awk -F'|' 'NF >= 5 { p = $2; v = $3; gsub(/[ `]/, "", p); gsub(/[ `]/, "", v)
		if (p != "" && p != "Package" && p !~ /^-+$/) print p " " v }'
done)
waiting=$(bash "$SUITE" waiting | while read -r pkg tver rver; do
	grep -qxF "$pkg $tver" <<< "$pending" || echo "$pkg $tver $rver"
done)

if [ -n "$answered" ]; then
	gh issue close "$answered" -R "$R" --comment "$1" >/dev/null
fi
if [ -z "$waiting" ]; then
	if [ -n "$num" ]; then
		if [ -n "$answered" ]; then gh issue close "$num" -R "$R" --comment "Nothing is waiting in testing now." >/dev/null
		else gh issue close "$num" -R "$R" --comment "$1 Nothing is waiting in testing now." >/dev/null; fi
	fi
	exit 0
fi

# What's waiting comes first, a package and its version to a line: GitHub's push
# notification for a new issue shows the start of its body (a few lines), and promote.yml
# reads the table, so no | in them.
summary=$(while read -r pkg tver rver; do printf '%s %s\n' "$pkg" "$tver"; done <<< "$waiting")
# What's new in each that publishes notes (news/<package>.news beside the pool, from commits' News: lines), newest first: those after the released version, up to the one in testing (for a package not released yet, its latest twelve). A package with no notes file (a kernel's headers, say) isn't listed.
REPO=${APT_REPO_DIR:-apt-repo}
news=$(while read -r pkg tver rver; do
	[ -f "$REPO/news/$pkg.news" ] || continue
	notes=$(while IFS=$'\t' read -r nv note; do
		dpkg --compare-versions "$nv" le "$tver" || continue
		[ "$rver" != none ] && dpkg --compare-versions "$nv" le "$rver" && break
		printf -- '- %s\n' "${note//|//}"   # (no | to look like a row of the table, which promote.yml reads)
	done < "$REPO/news/$pkg.news")
	n=$(grep -c . <<< "$notes" || true)
	printf '\n**%s %s**\n' "$pkg" "$tver"
	if [ "$n" -eq 0 ]; then
		echo "No news, just bug fixes and improvements."
	else
		head -n 12 <<< "$notes"
		[ "$n" -le 12 ] || echo "- and $((n - 12)) more before these"
	fi
done <<< "$waiting")
[ -n "$news" ] || news=$'\n'"No news, just bug fixes and improvements."
# What to check, the same every time, if the repository says (testing-checks.md beside this script: the kernel's list)
checks=""
CHECKS="$(dirname "$0")/testing-checks.md"
[ -s "$CHECKS" ] && checks=$'\n\n### What to check\n\n'"$(cat "$CHECKS")"

body="${summary}

| Package | In testing | Released |
|---|---|---|
$(while read -r pkg tver rver; do printf '| %s | %s | %s |\n' "$pkg" "$tver" "$rver"; done <<< "$waiting")

### What's new
${news}${checks}

Reply **ok** to release to every OpenFrame, or **no** to keep back."

if [ -n "$num" ]; then
	# (and assigned, in case it was opened without: GitHub tells only the assignee)
	gh issue edit "$num" -R "$R" --body "$body" ${ASSIGNEE:+--add-assignee "$ASSIGNEE"} >/dev/null
	# (after a promotion, the issue's only brought up to date: the comment is the answered one's)
	[ -n "$answered" ] || gh issue comment "$num" -R "$R" --body "$1" >/dev/null
else
	msg=$1
	[ -z "$answered" ] || msg="Still in testing after #${answered}."
	gh label create testing -R "$R" --color FBCA04 --description "Waiting in testing, reply ok to release, no to keep back" --force >/dev/null
	gh issue create -R "$R" --title "Waiting in testing: ${SITE}" --label testing \
		${ASSIGNEE:+--assignee "$ASSIGNEE"} --body "$body

$msg" >/dev/null
fi
