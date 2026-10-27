#!/usr/bin/env bash
# Rebuild the public-tracker lists from upstream sources + a local
# hand-picked list, then refresh the stats block in README.md.
# Run by .github/workflows/update-trackers.yml on a weekly schedule.
#
# Produces two files:
#   trackers_all_in_one.txt   broad union of every source (maximum coverage)
#   trackers_best.txt         curated/monitored lists only (leaner, more reliable)
#
# Resilient by design: unreachable sources are skipped with a warning,
# and a list is written only when it clears a minimum count, so a
# transient outage never wipes a published list.
set -euo pipefail

# Curated / monitored lists -> go into BOTH best and all.
BEST_SOURCES=(
  "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt"
  "https://newtrackon.com/api/stable"
  "https://cf.trackerslist.com/best.txt"
  "https://raw.githubusercontent.com/adysec/tracker/main/trackers_best.txt"
  "https://trackers.run/s/wp_up_hp_hs_v4_v6.txt"
)
# Broad aggregators -> added only to the full list.
EXTRA_SOURCES=(
  "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt"
  "https://cf.trackerslist.com/all.txt"
  "https://github.itzmx.com/1265578519/OpenTracker/master/tracker.txt"
  "https://raw.githubusercontent.com/Tunglies/TrackersList/main/all.txt"
  "https://raw.githubusercontent.com/mrgusux/automatic-trackers/main/all_trackers.txt"
)
# Hand-picked trackers kept in-repo; always included in both lists, first.
LOCAL_SOURCES=( sources/extra.txt )

MIN_TRACKERS=20   # safety floor per file: never overwrite with a near-empty result
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

best_files=()
all_files=()

# Local files first so hand-picked trackers rank near the top.
for f in "${LOCAL_SOURCES[@]}"; do
  if [ -f "$f" ]; then best_files+=("$f"); all_files+=("$f"); fi
done

fetch() {  # $1=url -> prints temp path on success, non-zero on failure
  local url="$1" out
  out="$(mktemp "$TMP/src.XXXXXX")"
  if curl -fsSL --max-time 60 -A "$UA" "$url" -o "$out" 2>/dev/null; then
    echo "  ok   $url" >&2
    printf '%s\n' "$out"
  else
    rm -f "$out"
    echo "  WARN skipped (unreachable): $url" >&2
    return 1
  fi
}

for url in "${BEST_SOURCES[@]}"; do
  if p="$(fetch "$url")"; then best_files+=("$p"); all_files+=("$p"); fi
done
for url in "${EXTRA_SOURCES[@]}"; do
  if p="$(fetch "$url")"; then all_files+=("$p"); fi
done

clean_merge() {  # $1=out, rest=input files
  local out="$1"; shift
  if [ "$#" -eq 0 ]; then : > "$out"; return; fi
  cat "$@" 2>/dev/null \
    | tr -d '\r' | sed 's/[[:space:]]*$//' \
    | grep -iE '^(udp|https?|wss?)://' \
    | awk '!seen[$0]++' > "$out"
}

clean_merge "$TMP/best.txt" "${best_files[@]}"
clean_merge "$TMP/all.txt"  "${all_files[@]}"

N_BEST=$(wc -l < "$TMP/best.txt" | tr -d '[:space:]')
N_ALL=$(wc -l < "$TMP/all.txt"  | tr -d '[:space:]')
if [ "$N_ALL" -lt "$MIN_TRACKERS" ] || [ "$N_BEST" -lt "$MIN_TRACKERS" ]; then
  echo "ERROR: too few trackers (all=$N_ALL best=$N_BEST, min=$MIN_TRACKERS); refusing to overwrite." >&2
  exit 1
fi
mv "$TMP/all.txt"  trackers_all_in_one.txt
mv "$TMP/best.txt" trackers_best.txt
echo "Built: all=$N_ALL best=$N_BEST"

# Nothing to do if neither file changed from what is already committed.
if git diff --quiet -- trackers_all_in_one.txt trackers_best.txt 2>/dev/null; then
  echo "Lists unchanged; nothing to do."
  exit 0
fi

row() {  # $1=label $2=file -> a markdown table row
  local f="$2"
  printf '| %-8s | %s | %s | %s | %s | %s |\n' "$1" \
    "$(wc -l < "$f" | tr -d '[:space:]')" \
    "$(grep -c '^udp://'     "$f" || true)" \
    "$(grep -c '^http://'    "$f" || true)" \
    "$(grep -c '^https://'   "$f" || true)" \
    "$(grep -icE '^wss?://'  "$f" || true)"
}

DATE=$(date -u +%Y-%m-%d)
{
  echo "**${N_ALL} trackers** in [\`trackers_all_in_one.txt\`](trackers_all_in_one.txt) · **${N_BEST}** in [\`trackers_best.txt\`](trackers_best.txt) — last updated **${DATE}** UTC"
  echo
  echo "| List     | Total | udp | http | https | ws/wss |"
  echo "|----------|-------|-----|------|-------|--------|"
  row "all"  trackers_all_in_one.txt
  row "best" trackers_best.txt
} > "$TMP/block.md"

awk -v f="$TMP/block.md" '
  /<!-- stats:start -->/ { print; while ((getline line < f) > 0) print line; skip=1; next }
  /<!-- stats:end -->/   { skip=0 }
  !skip
' README.md > "$TMP/README.new"
mv "$TMP/README.new" README.md

echo "Done."
