#!/usr/bin/env bash
# Re-fetch the three upstream tracker lists, merge + dedupe into
# trackers_all_in_one.txt, and refresh the stats block in README.md.
# Run by .github/workflows/update-trackers.yml on a weekly schedule.
set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading sources..."
curl -sfL "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt" -o "$TMP/ngosang.txt"
curl -sfL "https://newtrackon.com/api/stable"                                               -o "$TMP/newtrackon.txt"
curl -sfL "https://cf.trackerslist.com/best.txt"                                            -o "$TMP/cf_best.txt"

echo "Merging and deduplicating..."
cat "$TMP/ngosang.txt" "$TMP/newtrackon.txt" "$TMP/cf_best.txt" \
  | tr -d '\r' | sed 's/[[:space:]]*$//' | grep -v '^$' \
  | awk '!seen[$0]++' > trackers_all_in_one.txt

# Skip the rest if the merged list is identical to what is already committed.
if git diff --quiet -- trackers_all_in_one.txt 2>/dev/null; then
  echo "Tracker list unchanged; nothing to do."
  exit 0
fi

TOTAL=$(wc -l < trackers_all_in_one.txt | tr -d '[:space:]')
UDP=$(grep -c '^udp://'    trackers_all_in_one.txt || true)
HTTP=$(grep -c '^http://'   trackers_all_in_one.txt || true)
HTTPS=$(grep -c '^https://' trackers_all_in_one.txt || true)
WS=$(grep -c '^ws'         trackers_all_in_one.txt || true)
DATE=$(date -u +%Y-%m-%d)

echo "Updating README stats: ${TOTAL} trackers (${DATE})"
{
  echo "**${TOTAL} unique trackers** (last updated: **${DATE}** UTC)"
  echo
  echo "| Protocol | Count |"
  echo "|----------|-------|"
  echo "| udp      | ${UDP} |"
  echo "| http     | ${HTTP} |"
  echo "| https    | ${HTTPS} |"
  echo "| ws (WebSocket) | ${WS} |"
} > "$TMP/block.md"

awk -v f="$TMP/block.md" '
  /<!-- stats:start -->/ { print; while ((getline line < f) > 0) print line; skip=1; next }
  /<!-- stats:end -->/   { skip=0 }
  !skip
' README.md > "$TMP/README.new"
mv "$TMP/README.new" README.md

echo "Done."
