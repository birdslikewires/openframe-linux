#!/bin/bash
# testing-issue.sh: keeps the repository's "Waiting in testing" issue in step with the apt
# repository (ci/apt-suite.sh waiting), after a publish to the testing suite or a promotion.
# One open issue, labelled testing and assigned to ASSIGNEE (the workflows give Andy's login: the
# repositories belong to an organisation, which can't be assigned), lists what test units
# have that other OpenFrames don't yet; each change is a comment on it, which GitHub sends to the
# assignee (the GitHub app, and email). With nothing waiting, it's closed. "ok" or "no" as a reply
# on it starts promote.yml. Under the table, what's new in each package since the version every
# OpenFrame has, from news/<package>.news beside the pool (commits' News: lines), for whoever's
# testing. Run from the repository's root, after apt-suite.sh, with GH_TOKEN (issues: write)
# and GITHUB_REPOSITORY.
#   testing-issue.sh "<what just happened, a sentence>"
set -eu
SITE=${APT_SITE:-linux.openbeak.net}
SUITE=${APT_SUITE_SCRIPT:-ci/apt-suite.sh}
R="$GITHUB_REPOSITORY"
waiting=$(bash "$SUITE" waiting)
num=$(gh issue list -R "$R" --label testing --state open --json number -q '.[0].number')

if [ -z "$waiting" ]; then
	if [ -n "$num" ]; then
		gh issue close "$num" -R "$R" --comment "$1 Nothing is waiting in testing now."
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
	gh issue comment "$num" -R "$R" --body "$1" >/dev/null
else
	gh label create testing -R "$R" --color FBCA04 --description "Waiting in testing, reply ok to release, no to keep back" --force >/dev/null
	gh issue create -R "$R" --title "Waiting in testing: ${SITE}" --label testing \
		${ASSIGNEE:+--assignee "$ASSIGNEE"} --body "$body

$1" >/dev/null
fi
