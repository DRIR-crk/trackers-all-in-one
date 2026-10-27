#!/usr/bin/env bash
# Re-fetch upstream public-tracker lists, merge + dedupe into
# trackers_all_in_one.txt, and refresh the stats block in README.md.
# Run by .github/workflows/update-trackers.yml on a weekly schedule.
#
# Resilient by design: a source that is unreachable is skipped with a
# warning, and the merged list is written only when it clears a minimum
# count, so a transient outage never wipes the published list.
set -euo pipefail

# Curated / monitored lists first, broad aggregators last, so the most
# reliable trackers end up near the top of the file.
SOURCES=(
  "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt"
  "https://newtrackon.com/api/stable"
  "https://cf.trackerslist.com/best.txt"
  "https://raw.githubusercontent.com/adysec/tracker/main/trackers_best.txt"
  "https://trackers.run/s/wp_up_hp_hs_v4_v6.txt"
  "https://cf.trackerslist.com/all.txt"
  "https://github.itzmx.com/1265578519/OpenTracker/master/tracker.txt"
  "https://raw.githubusercontent.com/Tunglies/TrackersList/main/all.txt"
  "https://raw.githubusercontent.com/mrgusux/automatic-trackers/main/all_trackers.txt"
)

MIN_TRACKERS=50   # safety floor: never overwrite with a near-empty result
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/raw.txt"

ok=0
for url in "${SOURCES[@]}"; do
  if curl -fsSL --max-time 60 -A "$UA" "$url" >> "$TMP/raw.txt" 2>/dev/null; then
    printf '\n' >> "$TMP/raw.txt"
    ok=$((ok + 1))
    echo "  ok   $url"
  else
    echo "  WARN skipped (unreachable): $url" >&2
  fi
done
echo "Fetched ${ok}/${#SOURCES[@]} sources."

# Keep only real tracker URLs, strip CR/trailing whitespace, dedupe (first wins, order kept).
tr -d '\r' < "$TMP/raw.txt" \
  | sed 's/[[:space:]]*$//' \
  | grep -iE '^(udp|https?|wss?)://' \
  | awk '!seen[$0]++' > "$TMP/merged.txt"

COUNT=$(wc -l < "$TMP/merged.txt" | tr -d '[:space:]')
if [ "$COUNT" -lt "$MIN_TRACKERS" ]; then
  echo "ERROR: only ${COUNT} trackers (< ${MIN_TRACKERS}); refusing to overwrite." >&2
  exit 1
fi
mv "$TMP/merged.txt" trackers_all_in_one.txt

# Nothing to do if the list is byte-for-byte what is already committed.
if git diff --quiet -- trackers_all_in_one.txt 2>/dev/null; then
  echo "Tracker list unchanged (${COUNT} trackers); nothing to do."
  exit 0
fi

UDP=$(grep -c '^udp://'     trackers_all_in_one.txt || true)
HTTP=$(grep -c '^http://'    trackers_all_in_one.txt || true)
HTTPS=$(grep -c '^https://'  trackers_all_in_one.txt || true)
WS=$(grep -icE '^wss?://'   trackers_all_in_one.txt || true)
DATE=$(date -u +%Y-%m-%d)

echo "Updating README stats: ${COUNT} trackers (${DATE})"
{
  echo "**${COUNT} unique trackers** (last updated: **${DATE}** UTC)"
  echo
  echo "| Protocol | Count |"
  echo "|----------|-------|"
  echo "| udp      | ${UDP} |"
  echo "| http     | ${HTTP} |"
  echo "| https    | ${HTTPS} |"
  echo "| ws / wss | ${WS} |"
} > "$TMP/block.md"

awk -v f="$TMP/block.md" '
  /<!-- stats:start -->/ { print; while ((getline line < f) > 0) print line; skip=1; next }
  /<!-- stats:end -->/   { skip=0 }
  !skip
' README.md > "$TMP/README.new"
mv "$TMP/README.new" README.md

echo "Done."
