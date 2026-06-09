#!/usr/bin/env python3
"""Generate deterministic ZIP filename-encoding fixtures.

The ZIP files are built byte-for-byte from local and central directory records so
legacy filenames can be stored with bit 11 clear and without Python's zipfile
UTF-8 rewriting.
"""

from __future__ import annotations

import argparse
import binascii
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Fixtures"
MANIFEST = OUT / "filename_encoding_manifest.tsv"

VERSION_NEEDED = 20
VERSION_MADE_BY_UNIX = (3 << 8) | VERSION_NEEDED
UTF8_FLAG = 1 << 11
DOS_TIME_MIDNIGHT = 0
DOS_DATE_1980_01_01 = (1 << 5) | 1
UNIX_REGULAR_FILE_MODE = 0o100644 << 16


@dataclass(frozen=True)
class EntrySpec:
    path: str
    text: str
    expected_path: str = ""


@dataclass(frozen=True)
class FixtureSpec:
    artifact: str
    filename_encoding: str
    expected_archive_encoding: str
    utf8_flag: bool
    entries: tuple[EntrySpec, ...]


FIXTURES: tuple[FixtureSpec, ...] = (
    FixtureSpec(
        artifact="zip_filename_gbk.zip",
        filename_encoding="gbk",
        expected_archive_encoding="gb18030",
        utf8_flag=False,
        entries=(
            EntrySpec("中国人民银行营业公告.txt", "GBK top-level filename fixture."),
            EntrySpec("中文资料夹/季度财务报告.txt", "GBK one-level nested filename fixture."),
            EntrySpec("北京市档案馆/朝阳区资料/建设项目审批通知书.txt", "GBK two-level nested filename fixture."),
        ),
    ),
    FixtureSpec(
        artifact="zip_filename_gb18030.zip",
        filename_encoding="gb18030",
        expected_archive_encoding="gb18030",
        utf8_flag=False,
        entries=(
            EntrySpec("犇羴鱻鑫淼焱垚资料.txt", "GB18030 top-level filename fixture."),
            EntrySpec("扩展汉字目录/㐀㐁㐂㐃测试文件.txt", "GB18030 one-level nested filename fixture."),
            EntrySpec("国家标准字符集/生僻字样本/㐄㐅㐆㐇编码报告.txt", "GB18030 two-level nested filename fixture."),
        ),
    ),
    FixtureSpec(
        artifact="zip_filename_big5.zip",
        filename_encoding="big5",
        expected_archive_encoding="big5",
        utf8_flag=False,
        entries=(
            EntrySpec("臺灣大學招生簡章.txt", "Big5 top-level filename fixture."),
            EntrySpec("繁體資料夾/會議記錄檔案.txt", "Big5 one-level nested filename fixture."),
            EntrySpec("臺北市政府/環境保護局/資源回收公告.txt", "Big5 two-level nested filename fixture."),
        ),
    ),
    FixtureSpec(
        artifact="zip_filename_shift_jis.zip",
        filename_encoding="shift_jis",
        expected_archive_encoding="shiftJIS",
        utf8_flag=False,
        entries=(
            EntrySpec("日本語ファイル名テスト.txt", "Shift-JIS top-level filename fixture."),
            EntrySpec("東京都資料/会議議事録.txt", "Shift-JIS one-level nested filename fixture."),
            EntrySpec("大阪府立大学/工学研究科/入学試験問題集.txt", "Shift-JIS two-level nested filename fixture."),
        ),
    ),
    FixtureSpec(
        artifact="zip_filename_euc_kr.zip",
        filename_encoding="euc_kr",
        expected_archive_encoding="eucKR",
        utf8_flag=False,
        entries=(
            EntrySpec("한국어파일명이름테스트.txt", "EUC-KR top-level filename fixture."),
            EntrySpec("서울특별시자료/행정민원공지사항.txt", "EUC-KR one-level nested filename fixture."),
            EntrySpec("한국전자통신연구원/연구개발보고서/중간성과자료.txt", "EUC-KR two-level nested filename fixture."),
        ),
    ),
    FixtureSpec(
        artifact="zip_filename_cp437.zip",
        filename_encoding="cp437",
        expected_archive_encoding="cp437",
        utf8_flag=False,
        entries=(
            EntrySpec("über-große-Straße.txt", "CP437 top-level filename fixture."),
            EntrySpec("España-México/niño-año-canción.txt", "CP437 one-level nested filename fixture."),
            EntrySpec("français-résumé/café-protégé/élève-déjà-vu.txt", "CP437 two-level nested filename fixture."),
        ),
    ),
    FixtureSpec(
        artifact="zip_filename_cp850.zip",
        filename_encoding="cp850",
        expected_archive_encoding="cp850",
        utf8_flag=False,
        entries=(
            EntrySpec("Øresund-Portugal-Espanha-França-Ílhavo-Føroya.txt", "CP850 top-level filename fixture."),
            EntrySpec("Sverige-Norge-Danmark/Øst-Øresund-Álbum-Âncora-Àrvore-ã.txt", "CP850 one-level nested filename fixture."),
            EntrySpec("Österreich-Schweiz/België-Nederland/Øresund-Êxito-Ëvora-Èvora-Óbidos.txt", "CP850 two-level nested filename fixture."),
        ),
    ),
    FixtureSpec(
        artifact="zip_filename_cp1252.zip",
        filename_encoding="cp1252",
        expected_archive_encoding="windows1252",
        utf8_flag=False,
        entries=(
            EntrySpec("rapport-annuel-d’activité.txt", "Windows-1252 top-level filename fixture."),
            EntrySpec("café-naïve-résumé/élève-protégé.txt", "Windows-1252 one-level nested filename fixture."),
            EntrySpec("bilan-–-synthèse/Großbritannien-Straße/devis-€-final.txt", "Windows-1252 two-level nested filename fixture."),
        ),
    ),
    FixtureSpec(
        artifact="zip_filename_utf8_noflag.zip",
        filename_encoding="utf-8",
        expected_archive_encoding="none",
        utf8_flag=False,
        entries=(
            EntrySpec("中文文件名编码检测.txt", "UTF-8 no-flag top-level filename fixture."),
            EntrySpec("日本語資料/ファイル名テスト.txt", "UTF-8 no-flag one-level nested filename fixture."),
            EntrySpec("한국어자료/اختبار-العربية/混合言語ファイル.txt", "UTF-8 no-flag two-level nested filename fixture."),
        ),
    ),
    FixtureSpec(
        artifact="zip_filename_utf8_baseline.zip",
        filename_encoding="utf-8",
        expected_archive_encoding="none",
        utf8_flag=True,
        entries=(
            EntrySpec("中文文件名编码检测.txt", "UTF-8 baseline top-level filename fixture."),
            EntrySpec("日本語資料/ファイル名テスト.txt", "UTF-8 baseline one-level nested filename fixture."),
            EntrySpec("한국어자료/اختبار-العربية/混合言語ファイル.txt", "UTF-8 baseline two-level nested filename fixture."),
        ),
    ),
)


@dataclass(frozen=True)
class GeneratedEntry:
    fixture: FixtureSpec
    index: int
    raw_name: bytes


def le16(value: int) -> bytes:
    return struct.pack("<H", value)


def le32(value: int) -> bytes:
    return struct.pack("<I", value)


def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def encoded_path(entry: EntrySpec, encoding: str) -> bytes:
    return entry.path.encode(encoding)


def local_header(raw_name: bytes, payload: bytes, flags: int) -> bytes:
    return b"".join(
        [
            b"PK\x03\x04",
            le16(VERSION_NEEDED),
            le16(flags),
            le16(0),
            le16(DOS_TIME_MIDNIGHT),
            le16(DOS_DATE_1980_01_01),
            le32(crc32(payload)),
            le32(len(payload)),
            le32(len(payload)),
            le16(len(raw_name)),
            le16(0),
            raw_name,
            payload,
        ]
    )


def central_directory_entry(raw_name: bytes, payload: bytes, flags: int, local_offset: int) -> bytes:
    return b"".join(
        [
            b"PK\x01\x02",
            le16(VERSION_MADE_BY_UNIX),
            le16(VERSION_NEEDED),
            le16(flags),
            le16(0),
            le16(DOS_TIME_MIDNIGHT),
            le16(DOS_DATE_1980_01_01),
            le32(crc32(payload)),
            le32(len(payload)),
            le32(len(payload)),
            le16(len(raw_name)),
            le16(0),
            le16(0),
            le16(0),
            le16(0),
            le32(UNIX_REGULAR_FILE_MODE),
            le32(local_offset),
            raw_name,
        ]
    )


def build_zip(fixture: FixtureSpec) -> tuple[bytes, list[GeneratedEntry]]:
    flags = UTF8_FLAG if fixture.utf8_flag else 0
    local_records: list[bytes] = []
    central_records: list[bytes] = []
    generated: list[GeneratedEntry] = []
    offset = 0

    for index, entry in enumerate(fixture.entries):
        raw_name = encoded_path(entry, fixture.filename_encoding)
        payload = (entry.text + "\n").encode("utf-8")
        local = local_header(raw_name, payload, flags)
        local_records.append(local)
        central_records.append(central_directory_entry(raw_name, payload, flags, offset))
        generated.append(GeneratedEntry(fixture=fixture, index=index, raw_name=raw_name))
        offset += len(local)

    body = b"".join(local_records)
    central_start = len(body)
    central = b"".join(central_records)
    central_size = len(central)
    eocd = b"".join(
        [
            b"PK\x05\x06",
            le16(0),
            le16(0),
            le16(len(fixture.entries)),
            le16(len(fixture.entries)),
            le32(central_size),
            le32(central_start),
            le16(0),
        ]
    )
    return body + central + eocd, generated


def manifest_header() -> str:
    return "\t".join(
        [
            "artifact",
            "entry_index",
            "filename_encoding",
            "expected_archive_encoding",
            "utf8_flag",
            "has_unicode_path",
            "unicode_path_valid",
            "expected_path",
            "raw_name_hex",
            "unicode_path_hex",
        ]
    )


def manifest_line(entry: GeneratedEntry) -> str:
    fixture = entry.fixture
    return "\t".join(
        [
            fixture.artifact,
            str(entry.index),
            fixture.filename_encoding,
            fixture.expected_archive_encoding,
            "yes" if fixture.utf8_flag else "no",
            "no",
            "no",
            fixture.entries[entry.index].expected_path or fixture.entries[entry.index].path,
            entry.raw_name.hex(),
            "none",
        ]
    )


def generate_outputs() -> dict[Path, bytes]:
    outputs: dict[Path, bytes] = {}
    manifest_lines = [manifest_header()]

    for fixture in FIXTURES:
        archive_bytes, entries = build_zip(fixture)
        outputs[OUT / fixture.artifact] = archive_bytes
        manifest_lines.extend(manifest_line(entry) for entry in entries)

    outputs[MANIFEST] = ("\n".join(manifest_lines) + "\n").encode("utf-8")
    return outputs


def parse_central_directory(path: Path) -> list[tuple[int, bytes]]:
    data = path.read_bytes()
    eocd_index = data.rfind(b"PK\x05\x06")
    if eocd_index < 0:
        raise ValueError(f"{path.name}: missing EOCD")
    if eocd_index + 22 > len(data):
        raise ValueError(f"{path.name}: truncated EOCD")

    entry_count = struct.unpack_from("<H", data, eocd_index + 10)[0]
    central_size = struct.unpack_from("<I", data, eocd_index + 12)[0]
    central_offset = struct.unpack_from("<I", data, eocd_index + 16)[0]
    if central_offset + central_size > len(data):
        raise ValueError(f"{path.name}: central directory out of bounds")

    offset = central_offset
    names: list[tuple[int, bytes]] = []
    for index in range(entry_count):
        if data[offset : offset + 4] != b"PK\x01\x02":
            raise ValueError(f"{path.name}: missing central header at entry {index}")
        flags = struct.unpack_from("<H", data, offset + 8)[0]
        name_length = struct.unpack_from("<H", data, offset + 28)[0]
        extra_length = struct.unpack_from("<H", data, offset + 30)[0]
        comment_length = struct.unpack_from("<H", data, offset + 32)[0]
        name_start = offset + 46
        name_end = name_start + name_length
        if name_end > len(data):
            raise ValueError(f"{path.name}: filename out of bounds at entry {index}")
        names.append((flags, bytes(data[name_start:name_end])))
        offset = name_end + extra_length + comment_length

    if offset != central_offset + central_size:
        raise ValueError(f"{path.name}: central directory size mismatch")
    return names


def validate_outputs() -> None:
    rows = MANIFEST.read_text(encoding="utf-8").splitlines()
    if rows[0] != manifest_header():
        raise ValueError("manifest header mismatch")

    manifest_by_artifact: dict[str, list[list[str]]] = {}
    for line in rows[1:]:
        columns = line.split("\t")
        if len(columns) != 10:
            raise ValueError(f"manifest row has {len(columns)} columns: {line}")
        manifest_by_artifact.setdefault(columns[0], []).append(columns)

    for fixture in FIXTURES:
        archive_path = OUT / fixture.artifact
        names = parse_central_directory(archive_path)
        manifest_rows = manifest_by_artifact.get(fixture.artifact, [])
        if len(names) != len(fixture.entries):
            raise ValueError(f"{fixture.artifact}: expected {len(fixture.entries)} entries, got {len(names)}")
        if len(manifest_rows) != len(fixture.entries):
            raise ValueError(f"{fixture.artifact}: expected {len(fixture.entries)} manifest rows, got {len(manifest_rows)}")
        for index, ((flags, raw_name), row) in enumerate(zip(names, manifest_rows)):
            expected_flag = UTF8_FLAG if fixture.utf8_flag else 0
            if flags & UTF8_FLAG != expected_flag:
                raise ValueError(f"{fixture.artifact} entry {index}: UTF-8 flag mismatch")
            if int(row[1]) != index:
                raise ValueError(f"{fixture.artifact} entry {index}: manifest index mismatch")
            expected_path = fixture.entries[index].expected_path or fixture.entries[index].path
            if row[7] != expected_path:
                raise ValueError(f"{fixture.artifact} entry {index}: expected path mismatch")
            if row[8] != raw_name.hex():
                raise ValueError(f"{fixture.artifact} entry {index}: raw_name_hex mismatch")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate deterministic filename-encoding ZIP fixtures.")
    parser.add_argument("--check", action="store_true", help="verify files already match generated bytes")
    args = parser.parse_args()

    outputs = generate_outputs()
    if args.check:
        for path, expected in outputs.items():
            if not path.exists():
                print(f"missing {path.relative_to(OUT)}", file=sys.stderr)
                return 1
            actual = path.read_bytes()
            if actual != expected:
                print(f"stale {path.relative_to(OUT)}", file=sys.stderr)
                return 1
        validate_outputs()
        return 0

    for path, data in outputs.items():
        path.write_bytes(data)
    validate_outputs()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
