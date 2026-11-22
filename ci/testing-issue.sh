#!/bin/bash
# testing-issue.sh: keeps the repository's "Waiting in testing" issue in step with the apt
# repository (ci/apt-suite.sh waiting), after a publish to the testing suite or a promotion.
# One open issue, labelled testing and assigned to ASSIGNEE (the workflows give Andy's login: the
# repositories belong to an organisation, which can't be assigned), lists what test units
# have that other OpenFrames don't yet; each change is a comment on it, which GitHub sends to the
# assignee (the GitHub app, and email). With nothing waiting, it's closed. "promote" or "reject"
# on it starts promote.yml. Run from the repository's root, after apt-suite.sh, with GH_TOKEN
# (issues: write) and GITHUB_REPOSITORY.
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

body="Test units (OF-BOOT/settings/test.txt says \`testing=yes\`) take these from ${SITE}'s testing suite. Other OpenFrames don't have them yet.

| Package | In testing | Released |
|---|---|---|
$(while read -r pkg tver rver; do printf '| %s | %s | %s |\n' "$pkg" "$tver" "$rver"; done <<< "$waiting")

Comment **promote** to release them to every OpenFrame: they install overnight. Comment **reject** to close this and keep them back for now; the next publish opens it again."

if [ -n "$num" ]; then
	gh issue edit "$num" -R "$R" --body "$body" >/dev/null
	gh issue comment "$num" -R "$R" --body "$1" >/dev/null
else
	gh label create testing -R "$R" --color FBCA04 --description "Waiting in testing, for promote or reject" --force >/dev/null
	gh issue create -R "$R" --title "Waiting in testing: ${SITE}" --label testing \
		${ASSIGNEE:+--assignee "$ASSIGNEE"} --body "$body

$1" >/dev/null
fi
