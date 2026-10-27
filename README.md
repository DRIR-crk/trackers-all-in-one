# Trackers All-in-One

A single, deduplicated list of public BitTorrent trackers, merged from three well-maintained community sources.
Add it to your torrent client to speed up peer discovery for public torrents.

> **PT-BR:** Uma lista única de trackers públicos de BitTorrent, sem duplicatas, reunida a partir de três fontes da comunidade. Todo o crédito vai para os mantenedores originais (veja **Credits** abaixo).

## What's inside

- **[`trackers_all_in_one.txt`](trackers_all_in_one.txt)** — all trackers, one per line, duplicates removed.

**112 unique trackers** (last updated: **2026-10-27**)

| Protocol | Count |
|----------|-------|
| udp      | 63    |
| http     | 29    |
| https    | 19    |
| ws (WebSocket) | 1 |

## Usage

Direct raw link (paste into your client or script):

```
https://raw.githubusercontent.com/DRIR-crk/trackers-all-in-one/main/trackers_all_in_one.txt
```

- **qBittorrent** → Options → BitTorrent → *Automatically add these trackers to new downloads* → paste the list.
- **Transmission / Deluge / Vuze / BiglyBT** → add trackers to a torrent, one URL per line.

## Credits

This repository does not create any trackers of its own — it only merges and deduplicates lists that are built and maintained by others. **All credit goes to the original projects below.** Please star and support them:

- **ngosang/trackerslist** — <https://github.com/ngosang/trackerslist>
  Source: `trackers_all.txt`
- **newTrackon** — <https://newtrackon.com/>
  Source: `https://newtrackon.com/api/stable`
- **TrackersListCollection (XIU2)** — <https://github.com/XIU2/TrackersListCollection>
  Source: `https://cf.trackerslist.com/best.txt` (official CDN mirror)

The trackers and the underlying lists belong to their respective maintainers. Refer to each source project for its own license and terms of use.

## How it was built

```bash
# download the three sources
curl -sL https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt -o ngosang.txt
curl -sL https://newtrackon.com/api/stable                                               -o newtrackon.txt
curl -sL https://cf.trackerslist.com/best.txt                                            -o cf_best.txt

# merge, strip blank lines, and remove duplicates (keeping first occurrence)
cat ngosang.txt newtrackon.txt cf_best.txt \
  | tr -d '\r' | sed 's/[[:space:]]*$//' | grep -v '^$' \
  | awk '!seen[$0]++' > trackers_all_in_one.txt
```
