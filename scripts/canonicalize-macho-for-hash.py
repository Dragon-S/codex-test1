#!/usr/bin/python3

import struct
import sys
from pathlib import Path


LC_UUID = 0x1B
LC_SYMTAB = 0x02
N_TYPE = 0x0E
N_ABS = 0x02


def macho_slices(data: bytearray) -> list[int]:
    if len(data) < 8:
        return []

    magic = bytes(data[:4])
    if magic in (b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf"):
        return [0]
    if magic not in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        return []

    architecture_count = struct.unpack_from(">I", data, 4)[0]
    is_fat64 = magic == b"\xca\xfe\xba\xbf"
    entry_size = 32 if is_fat64 else 20
    offset_field = 8
    offset_format = ">Q" if is_fat64 else ">I"
    slices = []
    for index in range(architecture_count):
        entry = 8 + index * entry_size
        if entry + entry_size > len(data):
            raise ValueError("损坏的 Mach-O fat header")
        slices.append(struct.unpack_from(offset_format, data, entry + offset_field)[0])
    return slices


def clear_nondeterministic_fields(data: bytearray, slice_offset: int) -> None:
    magic = bytes(data[slice_offset : slice_offset + 4])
    layouts = {
        b"\xce\xfa\xed\xfe": ("<", 28),
        b"\xcf\xfa\xed\xfe": ("<", 32),
        b"\xfe\xed\xfa\xce": (">", 28),
        b"\xfe\xed\xfa\xcf": (">", 32),
    }
    if magic not in layouts:
        raise ValueError("fat archive 包含非 Mach-O slice")

    endian, header_size = layouts[magic]
    is_64_bit = header_size == 32
    command_count = struct.unpack_from(f"{endian}I", data, slice_offset + 16)[0]
    command_offset = slice_offset + header_size
    symbol_table = None
    for _ in range(command_count):
        if command_offset + 8 > len(data):
            raise ValueError("损坏的 Mach-O load command")
        command, command_size = struct.unpack_from(f"{endian}II", data, command_offset)
        if command_size < 8 or command_offset + command_size > len(data):
            raise ValueError("损坏的 Mach-O load command size")
        if command == LC_UUID:
            if command_size != 24:
                raise ValueError("异常的 LC_UUID 大小")
            data[command_offset + 8 : command_offset + 24] = bytes(16)
        elif command == LC_SYMTAB:
            symbol_table = struct.unpack_from(f"{endian}IIII", data, command_offset + 8)
        command_offset += command_size

    if symbol_table is None:
        return
    symbol_offset, symbol_count, string_offset, string_size = symbol_table
    entry_size = 16 if is_64_bit else 12
    value_offset = 8
    value_format = f"{endian}Q" if is_64_bit else f"{endian}I"
    string_base = slice_offset + string_offset
    string_end = string_base + string_size
    for index in range(symbol_count):
        entry = slice_offset + symbol_offset + index * entry_size
        if entry + entry_size > len(data):
            raise ValueError("损坏的 Mach-O symbol table")
        string_index, symbol_type = struct.unpack_from(f"{endian}IB", data, entry)
        if symbol_type & N_TYPE != N_ABS or string_index >= string_size:
            continue
        name_start = string_base + string_index
        name_end = data.find(0, name_start, string_end)
        if name_end < 0:
            raise ValueError("损坏的 Mach-O string table")
        symbol_name = bytes(data[name_start:name_end])
        if symbol_name.endswith(b".swiftmodule"):
            struct.pack_into(value_format, data, entry + value_offset, 0)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"用法：{Path(sys.argv[0]).name} <Mach-O 文件>")

    target = Path(sys.argv[1])
    data = bytearray(target.read_bytes())
    slices = macho_slices(data)
    for slice_offset in slices:
        clear_nondeterministic_fields(data, slice_offset)
    if slices:
        target.write_bytes(data)


if __name__ == "__main__":
    main()
