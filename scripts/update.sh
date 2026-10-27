#!/usr/bin/env bash
# Rebuild the public-tracker lists, then refresh the stats block in README.md.
# Run by .github/workflows/update-trackers.yml on a weekly schedule.
#
#   trackers_all_in_one.txt   union of every source (maximum coverage)
#   trackers_best.txt         OUR own list: only trackers that pass a live probe
#                             (scripts/check_trackers.py), regenerated each run
#
# Resilient: unreachable sources are skipped, and a file is written only when it
# clears a minimum count, so a transient outage never wipes a published list.
set -euo pipefail

SOURCES=(
  "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt"
  "https://newtrackon.com/api/stable"
  "https://cf.trackerslist.com/best.txt"
  "https://cf.trackerslist.com/all.txt"
  "https://raw.githubusercontent.com/adysec/tracker/main/trackers_best.txt"
  "https://trackers.run/s/wp_up_hp_hs_v4_v6.txt"
  "https://github.itzmx.com/1265578519/OpenTracker/master/tracker.txt"
  "https://raw.githubusercontent.com/Tunglies/TrackersList/main/all.txt"
  "https://raw.githubusercontent.com/mrgusux/automatic-trackers/main/all_trackers.txt"
)
# Hand-picked trackers kept in-repo; always included in the union, first.
LOCAL_SOURCES=( sources/extra.txt )

MIN_ALL=50        # floor for the full union
MIN_BEST=10       # floor for the live-tested list
PYTHON="${PYTHON:-python3}"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

inputs=()
for f in "${LOCAL_SOURCES[@]}"; do
  [ -f "$f" ] && inputs+=("$f")
done

echo "Fetching sources..."
ok=0
for url in "${SOURCES[@]}"; do
  out="$(mktemp "$TMP/src.XXXXXX")"
  if curl -fsSL --max-time 60 -A "$UA" "$url" -o "$out" 2>/dev/null; then
    inputs+=("$out"); ok=$((ok + 1)); echo "  ok   $url"
  else
    rm -f "$out"; echo "  WARN skipped (unreachable): $url" >&2
  fi
done
echo "Fetched ${ok}/${#SOURCES[@]} sources."

if [ "${#inputs[@]}" -eq 0 ]; then
  echo "ERROR: no sources available." >&2
  exit 1
fi

# Build the full union: valid tracker URLs only, trimmed, deduped (first wins).
cat "${inputs[@]}" 2>/dev/null \
  | tr -d '\r' | sed 's/[[:space:]]*$//' \
  | grep -iE '^(udp|https?|wss?)://' \
  | awk '!seen[$0]++' > "$TMP/all.txt"

N_ALL=$(wc -l < "$TMP/all.txt" | tr -d '[:space:]')
if [ "$N_ALL" -lt "$MIN_ALL" ]; then
  echo "ERROR: only ${N_ALL} trackers in the union (< ${MIN_ALL}); refusing to overwrite." >&2
  exit 1
fi

# Live-test every tracker; keep only the ones that actually respond.
echo "Live-testing ${N_ALL} trackers (this takes a few minutes)..."
"$PYTHON" scripts/check_trackers.py "$TMP/all.txt" "$TMP/best.txt"
N_BEST=$(wc -l < "$TMP/best.txt" | tr -d '[:space:]')
if [ "$N_BEST" -lt "$MIN_BEST" ]; then
  echo "ERROR: only ${N_BEST} trackers passed the live test (< ${MIN_BEST}); keeping the previous lists." >&2
  exit 1
fi

mv "$TMP/all.txt"  trackers_all_in_one.txt
mv "$TMP/best.txt" trackers_best.txt
echo "Built: all=${N_ALL} best=${N_BEST}"

# Nothing to do if neither file changed from what is already committed.
if git diff --quiet -- trackers_all_in_one.txt trackers_best.txt 2>/dev/null; then
  echo "No changes; nothing to do."
  exit 0
fi

row() {  # $1=label $2=file -> a markdown table row
  local f="$2"
  printf '| %-32s | %s | %s | %s | %s | %s |\n' "$1" \
    "$(wc -l < "$f" | tr -d '[:space:]')" \
    "$(grep -c '^udp://'    "$f" || true)" \
    "$(grep -c '^http://'   "$f" || true)" \
    "$(grep -c '^https://'  "$f" || true)" \
    "$(grep -icE '^wss?://' "$f" || true)"
}

DATE=$(date -u +%Y-%m-%d)
{
  echo "**${N_ALL} trackers** in [\`trackers_all_in_one.txt\`](trackers_all_in_one.txt) · **${N_BEST} live-tested** in [\`trackers_best.txt\`](trackers_best.txt) — last updated **${DATE}** UTC"
  echo
  echo "| List                             | Total | udp | http | https | ws/wss |"
  echo "|----------------------------------|-------|-----|------|-------|--------|"
  row "all (every source)"             trackers_all_in_one.txt
  row "best (responded to live probe)" trackers_best.txt
} > "$TMP/block.md"

awk -v f="$TMP/block.md" '
  /<!-- stats:start -->/ { print; while ((getline line < f) > 0) print line; skip=1; next }
  /<!-- stats:end -->/   { skip=0 }
  !skip
' README.md > "$TMP/README.new"
mv "$TMP/README.new" README.md

echo "Done."
