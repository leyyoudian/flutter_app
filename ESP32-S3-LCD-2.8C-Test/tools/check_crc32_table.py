from pathlib import Path
import re
import sys
import zlib


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "main" / "Badge" / "BadgeProtocol.c"


def load_table():
    source = SOURCE.read_text(encoding="utf-8")
    match = re.search(r"s_crc32_table\s*\[\s*256\s*\]\s*=\s*\{(?P<body>.*?)\};", source, re.S)
    if match is None:
        raise AssertionError("BadgeProtocol.c must define s_crc32_table[256]")
    values = [int(token, 16) for token in re.findall(r"0x[0-9a-fA-F]+", match.group("body"))]
    if len(values) != 256:
        raise AssertionError(f"CRC table has {len(values)} entries, expected 256")
    return values


def crc32_with_table(payload: bytes, table):
    crc = 0xFFFFFFFF
    for byte in payload:
        crc = ((crc >> 8) ^ table[(crc ^ byte) & 0xFF]) & 0xFFFFFFFF
    return crc ^ 0xFFFFFFFF


def main():
    table = load_table()
    vectors = [b"", b"123456789", b"ESP-BAJI", bytes(range(256))]
    for payload in vectors:
        got = crc32_with_table(payload, table)
        expected = zlib.crc32(payload) & 0xFFFFFFFF
        if got != expected:
            raise AssertionError(
                f"CRC mismatch for {payload!r}: got=0x{got:08x} expected=0x{expected:08x}"
            )


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
