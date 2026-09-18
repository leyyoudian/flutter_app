import argparse
import os
import socket
import struct
import zlib
from typing import Tuple

import pytest


DEFAULT_PORT = 3333


class BadgeProtocolClient:
    def __init__(self, host: str, port: int = DEFAULT_PORT, timeout: float = 5.0):
        self.host = host
        self.port = port
        self.timeout = timeout

    def command(self, command: str) -> str:
        with socket.create_connection((self.host, self.port), self.timeout) as sock:
            sock.settimeout(self.timeout)
            sock.sendall(command.encode("ascii"))
            response = bytearray()
            while len(response) < 256:
                chunk = sock.recv(1)
                if not chunk or chunk == b"\n":
                    break
                response.extend(chunk)
            return response.decode("ascii", errors="replace").strip()

    def upload(self, path: str) -> Tuple[str, int]:
        with open(path, "rb") as source:
            payload = source.read()
        crc32 = zlib.crc32(payload) & 0xFFFFFFFF
        header = struct.pack("<III", 0x31505542, len(payload), crc32)
        with socket.create_connection((self.host, self.port), self.timeout) as sock:
            sock.settimeout(max(self.timeout, 30.0))
            sock.sendall(header)
            assert self._read_line(sock) == "READY"
            sock.sendall(payload)
            response = self._read_line(sock)
        assert response.startswith("OK U"), response
        return response.split()[1], crc32

    @staticmethod
    def _read_line(sock: socket.socket) -> str:
        response = bytearray()
        while len(response) < 256:
            chunk = sock.recv(1)
            if not chunk or chunk == b"\n":
                break
            response.extend(chunk)
        return response.decode("ascii", errors="replace").strip()


def check_non_destructive_contract(client: BadgeProtocolClient) -> None:
    identity = client.command("IDENTITY\n")
    assert identity.startswith("OK DEVICE P4-"), identity
    assert len(identity) == len("OK DEVICE P4-") + 12, identity

    factory = client.command("DELETE F001 00000000\n")
    assert factory == "ERR FORBIDDEN", factory

    malformed = client.command("DELETE ../U001 00000000\n")
    assert malformed == "ERR INVALID", malformed


def check_disposable_asset_lifecycle(client: BadgeProtocolClient, asset_path: str) -> None:
    asset_id, crc32 = client.upload(asset_path)
    crc_text = f"{crc32:08x}"
    wrong_crc = f"{(crc32 ^ 0xFFFFFFFF):08x}"
    try:
        response = client.command(f"STAT {asset_id} {crc_text}\n")
        assert response == f"OK MATCH {asset_id}", response
        response = client.command(f"DELETE {asset_id} {wrong_crc}\n")
        assert response == f"OK STALE {asset_id}", response
        response = client.command(f"STAT {asset_id} {crc_text}\n")
        assert response == f"OK MATCH {asset_id}", response
        response = client.command(f"SWITCH {asset_id} {wrong_crc}\n")
        assert response == f"NEED_UPLOAD {asset_id}", response
        response = client.command(f"DELETE {asset_id} {crc_text}\n")
        assert response == f"OK DELETED {asset_id}", response
        response = client.command(f"STAT {asset_id} {crc_text}\n")
        assert response == f"OK MISSING {asset_id}", response
        response = client.command(f"DELETE {asset_id} {crc_text}\n")
        assert response == f"OK MISSING {asset_id}", response
    finally:
        client.command(f"DELETE {asset_id} {crc_text}\n")


@pytest.mark.hardware
def test_identity_and_factory_delete_guard() -> None:
    host = os.environ.get("BADGE_HOST")
    if not host:
        pytest.skip("set BADGE_HOST to run P4 protocol hardware tests")
    check_non_destructive_contract(BadgeProtocolClient(host))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--non-destructive", action="store_true")
    parser.add_argument("--asset")
    args = parser.parse_args()
    if not args.non_destructive and not args.asset:
        parser.error("select --non-destructive or provide --asset for a disposable lifecycle test")

    client = BadgeProtocolClient(args.host, args.port)
    if args.non_destructive:
        check_non_destructive_contract(client)
        print("P4 identity and factory delete guard: PASS")
    if args.asset:
        check_disposable_asset_lifecycle(client, args.asset)
        print("P4 disposable upload/status/delete lifecycle: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
