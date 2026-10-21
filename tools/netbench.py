#!/usr/bin/env python3
"""Minimal raw-TCP throughput probe for the Thunderbolt Bridge.

Usage:
  netbench.py server <port>          # receive until EOF, print byte count
  netbench.py client <host> <port> [MiB]   # send MiB and print Gbit/s

Runs over a plain TCP socket (no SSH encryption in the data path), so it
measures the bridge, not the SSH tunnel. Python overhead is negligible at
multi-gigabit rates on Apple silicon.
"""
import socket
import sys
import time

BLOCK = 1024 * 1024


def server(port: int) -> int:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(1)
    conn, addr = srv.accept()
    total = 0
    with conn:
        while True:
            data = conn.recv(256 * 1024)
            if not data:
                break
            total += len(data)
    srv.close()
    print(f"server received {total} bytes from {addr[0]}")
    return 0


def client(host: str, port: int, mib: int) -> int:
    sock = socket.create_connection((host, port), timeout=10)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    payload = b"\0" * BLOCK
    start = time.perf_counter()
    sent = 0
    with sock:
        for _ in range(mib):
            sock.sendall(payload)
            sent += len(payload)
        sock.shutdown(socket.SHUT_WR)
        # Drain any server response so close is graceful.
        while sock.recv(4096):
            pass
    elapsed = time.perf_counter() - start
    gbit = sent * 8 / elapsed / 1e9
    print(f"client sent {sent} bytes in {elapsed:.3f}s = {gbit:.2f} Gbit/s")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "server":
        raise SystemExit(server(int(sys.argv[2])))
    if len(sys.argv) >= 4 and sys.argv[1] == "client":
        mib = int(sys.argv[4]) if len(sys.argv) > 4 else 2048
        raise SystemExit(client(sys.argv[2], int(sys.argv[3]), mib))
    print(__doc__)
    raise SystemExit(2)
