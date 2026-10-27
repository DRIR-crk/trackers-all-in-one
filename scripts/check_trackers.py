#!/usr/bin/env python3
"""Live liveness test for BitTorrent trackers (standard library only).

Reads tracker URLs (one per line) from INPUT, probes each with the real
tracker protocol, and writes the ones that respond to OUTPUT, preserving the
input order.

  udp://      BEP 15 connect + announce handshake.
  http(s)://  a real announce request whose response must be valid bencode.
  ws(s)://    not probed (excluded from the output).

Usage: check_trackers.py INPUT OUTPUT
Env:   CHECK_WORKERS (default 200), CHECK_TIMEOUT in seconds (default 5)
"""
from __future__ import annotations

import concurrent.futures as cf
import os
import random
import socket
import ssl
import struct
import sys
import time
import urllib.parse
import urllib.request

UDP_MAGIC = 0x41727101980
WORKERS = int(os.environ.get("CHECK_WORKERS", "200"))
TIMEOUT = float(os.environ.get("CHECK_TIMEOUT", "5"))

# Trackers often have self-signed / mismatched certs; we care about reachability,
# not certificate validity, so verification is intentionally disabled.
_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode = ssl.CERT_NONE


def _rand(n: int) -> bytes:
    return random.getrandbits(8 * n).to_bytes(n, "big")


def _bdecode(data: bytes):
    """Minimal bencode decoder; raises ValueError on malformed input."""
    def parse(i: int):
        c = data[i:i + 1]
        if c == b"i":
            j = data.index(b"e", i)
            return int(data[i + 1:j]), j + 1
        if c == b"l":
            i += 1
            out = []
            while data[i:i + 1] != b"e":
                v, i = parse(i)
                out.append(v)
            return out, i + 1
        if c == b"d":
            i += 1
            out = {}
            while data[i:i + 1] != b"e":
                k, i = parse(i)
                v, i = parse(i)
                out[k] = v
            return out, i + 1
        if c.isdigit():
            j = data.index(b":", i)
            n = int(data[i:j])
            return data[j + 1:j + 1 + n], j + 1 + n
        raise ValueError("invalid bencode")

    value, _ = parse(0)
    return value


def _check_udp(host: str, port: int) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(TIMEOUT)
    try:
        s.connect((host, port))
        txn = random.getrandbits(32)
        connect_pkt = struct.pack(">QII", UDP_MAGIC, 0, txn)
        conn_id = None
        for _ in range(2):  # UDP is lossy; retry the connect step once
            try:
                s.send(connect_pkt)
                resp = s.recv(16)
            except socket.timeout:
                continue
            if len(resp) >= 16:
                action, rtxn = struct.unpack(">II", resp[:8])
                if action == 0 and rtxn == txn:
                    conn_id = struct.unpack(">Q", resp[8:16])[0]
                    break
        if conn_id is None:
            return False

        txn2 = random.getrandbits(32)
        announce = struct.pack(
            ">QII20s20sQQQIIIiH",
            conn_id, 1, txn2, _rand(20), b"-qB5010-" + _rand(12),
            0, 0, 0, 0, 0, random.getrandbits(32), -1, port,
        )
        for _ in range(2):
            try:
                s.send(announce)
                resp = s.recv(2048)
            except socket.timeout:
                continue
            if len(resp) >= 8:
                action, rtxn = struct.unpack(">II", resp[:8])
                if action == 1 and rtxn == txn2:
                    return True
        return False
    except OSError:
        return False
    finally:
        s.close()


def _check_http(url: str) -> bool:
    query = urllib.parse.urlencode({
        "info_hash": _rand(20),
        "peer_id": b"-qB5010-" + _rand(12),
        "port": 6881,
        "uploaded": 0,
        "downloaded": 0,
        "left": 0,
        "compact": 1,
        "numwant": 0,
        "event": "started",
    })
    full = url + ("&" if "?" in url else "?") + query
    req = urllib.request.Request(full, headers={"User-Agent": "qBittorrent/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=_SSL) as r:
            body = r.read(65536)
        # A live tracker answers with a bencoded dict, even to reject our fake
        # info_hash ("failure reason"). An HTML error page / timeout does not.
        return isinstance(_bdecode(body), dict)
    except Exception:
        return False


def probe(url: str) -> bool:
    try:
        p = urllib.parse.urlparse(url)
        scheme = p.scheme.lower()
        host = p.hostname
        if not host:
            return False
        if scheme == "udp":
            return _check_udp(host, p.port or 80)
        if scheme in ("http", "https"):
            return _check_http(url)
        return False  # ws/wss and anything else: not probed
    except Exception:
        return False


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: check_trackers.py INPUT OUTPUT\n")
        return 2
    inp, outp = sys.argv[1], sys.argv[2]

    seen, urls = set(), []
    with open(inp, encoding="utf-8", errors="replace") as f:
        for line in f:
            u = line.strip()
            if u and "://" in u and u not in seen:
                seen.add(u)
                urls.append(u)

    t0 = time.time()
    alive = set()
    with cf.ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futures = {ex.submit(probe, u): u for u in urls}
        for fut in cf.as_completed(futures):
            if fut.result():
                alive.add(futures[fut])

    ordered = [u for u in urls if u in alive]  # keep original ordering
    with open(outp, "w", encoding="utf-8", newline="\n") as f:
        if ordered:
            f.write("\n".join(ordered) + "\n")

    dt = time.time() - t0

    def count(prefix: str) -> int:
        return sum(1 for u in ordered if u.startswith(prefix))

    sys.stderr.write(
        f"Live test: {len(urls)} tested, {len(ordered)} alive in {dt:.0f}s "
        f"(udp {count('udp://')}, http {count('http://')}, https {count('https://')})\n"
    )
    print(len(ordered))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
