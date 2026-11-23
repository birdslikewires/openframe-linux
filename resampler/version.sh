#!/bin/bash
# Prints the openframe-resampler version, from the repository's root with its full history.
#
# Version is year.month.N, where N counts the commits that changed the package in that month
# (the third this month is 26.11.3), as for openframe-scripts (package/version.sh). Every path
# the package is built from is listed below, the workflow included, so a change to any of them
# gives a new version.

paths=(resampler .github/workflows/resampler.yml)
month=$(TZ=UTC git log -1 --format=%cd --date=format-local:%y.%m -- "${paths[@]}")
count=$(TZ=UTC git log --format=%cd --date=format-local:%y.%m -- "${paths[@]}" | grep -cx "${month}")
[ -n "$month" ] && [ "$count" -gt 0 ] || { echo "Can't work out the version: no history?" >&2; exit 1; }
echo "${month%.*}.$((10#${month#*.})).${count}"
