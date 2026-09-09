#!/usr/bin/env python3
"""
rbxl_parser.py — Roblox binary place file parser
Usage:
    python3 rbxl_parser.py <file.rbxl> [options]

Options:
    --tree              Print full instance tree
    --scripts           Dump all script sources
    --search <prop>     Search for a property name across all instances
    --class <name>      Filter tree to instances of this class
    --grep <text>       Grep script sources for text
"""

import sys
import struct
import io
import argparse
import json
from collections import defaultdict

try:
    import zstandard as zstd
except ImportError:
    zstd = None

try:
    import lz4.block as lz4
except ImportError:
    lz4 = None

MAGIC = b"<roblox!\x89\xff\r\n\x1a\n"

# Property type IDs
PROP_TYPES = {
    0x01: "String",
    0x02: "Bool",
    0x03: "Int32",
    0x04: "Float",
    0x05: "Double",
    0x06: "UDim",
    0x07: "UDim2",
    0x08: "Ray",
    0x09: "Faces",
    0x0A: "Axes",
    0x0B: "BrickColor",
    0x0C: "Color3",
    0x0D: "Vector2",
    0x0E: "Vector3",
    0x10: "CFrame",
    0x11: "CFrameSpecial",
    0x12: "Enum",
    0x13: "Ref",
    0x14: "Vector3int16",
    0x15: "NumberSequence",
    0x16: "ColorSequence",
    0x17: "NumberRange",
    0x18: "Rect2D",
    0x19: "PhysicalProperties",
    0x1A: "Color3uint8",
    0x1B: "Int64",
    0x1C: "SharedString",
    0x1E: "OptionalCFrame",
    0x1F: "UniqueId",
    0x20: "Font",
    0x21: "SecurityCapabilities",
}


def read_u8(b, pos):
    return b[pos], pos + 1

def read_u32(b, pos):
    return struct.unpack_from("<I", b, pos)[0], pos + 4

def read_i32(b, pos):
    return struct.unpack_from("<i", b, pos)[0], pos + 4

def read_f32(b, pos):
    return struct.unpack_from("<f", b, pos)[0], pos + 4

def read_f64(b, pos):
    return struct.unpack_from("<d", b, pos)[0], pos + 8

def read_string(b, pos):
    length, pos = read_u32(b, pos)
    s = b[pos:pos+length]
    return s.decode("utf-8", errors="replace"), pos + length

def read_bytes(b, pos):
    length, pos = read_u32(b, pos)
    return b[pos:pos+length], pos + length


def decompress_chunk(data, compressed_len, uncompressed_len):
    if compressed_len == 0:
        return data[:uncompressed_len]

    # Detect compression by magic
    if len(data) >= 4:
        magic4 = data[:4]
        if magic4 == b"\x28\xb5\x2f\xfd":  # zstd
            if zstd is None:
                raise RuntimeError("zstandard not installed: pip install zstandard")
            ctx = zstd.ZstdDecompressor()
            return ctx.decompress(data, max_output_size=uncompressed_len * 2)
        elif magic4[:2] == b"\x02\x21" or magic4 == b"\x04\x22\x4d\x18":  # LZ4 frame
            if lz4 is None:
                raise RuntimeError("lz4 not installed: pip install lz4")
            return lz4.decompress(data[4:], uncompressed_size=uncompressed_len)

    # LZ4 block (legacy Roblox format, no frame header)
    if lz4 is not None:
        try:
            return lz4.decompress(data, uncompressed_size=uncompressed_len)
        except Exception:
            pass

    return data


def de_interleave(data, count):
    """De-interleave byte arrays used in Roblox's array encoding."""
    out = bytearray(count * 4)
    for i in range(count):
        out[i*4]   = data[i]
        out[i*4+1] = data[count + i]
        out[i*4+2] = data[count*2 + i]
        out[i*4+3] = data[count*3 + i]
    return bytes(out)


def decode_float_array(data, count):
    raw = de_interleave(data, count)
    result = []
    for i in range(count):
        b = raw[i*4:(i+1)*4]
        # Roblox stores: rotate the float's bits left by 1, then big-endian
        # To decode: read big-endian u32, rotate right by 1 bit, reinterpret as f32
        u = struct.unpack(">I", b)[0]
        u = ((u >> 1) | ((u & 1) << 31)) & 0xFFFFFFFF
        result.append(struct.unpack(">f", struct.pack(">I", u))[0])
    return result


def decode_i32_array(data, count):
    raw = de_interleave(data, count)
    vals = [struct.unpack_from(">I", raw, i*4)[0] for i in range(count)]
    # Zigzag decode
    def zigzag(n):
        return (n >> 1) ^ -(n & 1)
    # Delta + zigzag
    prev = 0
    result = []
    for v in vals:
        prev += zigzag(v)
        result.append(prev)
    return result


def decode_ref_array(data, count):
    raw = de_interleave(data, count)
    vals = [struct.unpack_from(">i", raw, i*4)[0] for i in range(count)]
    prev = 0
    result = []
    for v in vals:
        prev += v
        result.append(prev)
    return result


class RbxlParser:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.raw = f.read()
        self.pos = 0
        self.classes = {}       # class_index -> {name, referents[]}
        self.instances = {}     # referent -> {class_name, props{}, children[]}
        self.parents = {}       # referent -> parent_referent
        self.shared_strings = []
        self._parse()

    def _parse(self):
        data = self.raw
        if not data.startswith(MAGIC):
            raise ValueError("Not a binary RBXL file")

        pos = len(MAGIC)
        pos += 2  # padding
        num_classes = struct.unpack_from("<I", data, pos)[0]; pos += 4
        num_instances = struct.unpack_from("<I", data, pos)[0]; pos += 4
        pos += 8  # reserved

        print(f"[rbxl] classes={num_classes} instances={num_instances}", file=sys.stderr)

        while pos < len(data):
            if pos + 16 > len(data):
                break
            chunk_name = data[pos:pos+4].rstrip(b"\x00").decode("ascii", errors="replace")
            compressed_len = struct.unpack_from("<I", data, pos+4)[0]
            uncompressed_len = struct.unpack_from("<I", data, pos+8)[0]
            pos += 16

            actual_len = compressed_len if compressed_len > 0 else uncompressed_len
            chunk_data = data[pos:pos+actual_len]
            pos += actual_len

            if chunk_name == "END":
                break

            try:
                raw = decompress_chunk(chunk_data, compressed_len, uncompressed_len)
            except Exception as e:
                print(f"[rbxl] failed to decompress {chunk_name}: {e}", file=sys.stderr)
                continue

            if chunk_name == "SSTR":
                self._parse_sstr(raw)
            elif chunk_name == "INST":
                self._parse_inst(raw)
            elif chunk_name == "PROP":
                self._parse_prop(raw)
            elif chunk_name == "PRNT":
                self._parse_prnt(raw)

        # Build children lists
        for ref, parent in self.parents.items():
            if parent != -1:
                if parent not in self.instances:
                    self.instances[parent] = {"class_name": "??", "props": {}, "children": []}
                self.instances[parent].setdefault("children", []).append(ref)

    def _parse_sstr(self, data):
        pos = 0
        count = struct.unpack_from("<I", data, pos)[0]; pos += 4
        pos += 4  # reserved
        for _ in range(count):
            md5 = data[pos:pos+16]; pos += 16
            length = struct.unpack_from("<I", data, pos)[0]; pos += 4
            s = data[pos:pos+length]; pos += length
            self.shared_strings.append(s)

    def _parse_inst(self, data):
        pos = 0
        class_index = struct.unpack_from("<I", data, pos)[0]; pos += 4
        name_len = struct.unpack_from("<I", data, pos)[0]; pos += 4
        name = data[pos:pos+name_len].decode("utf-8", errors="replace"); pos += name_len
        is_service = data[pos]; pos += 1
        count = struct.unpack_from("<I", data, pos)[0]; pos += 4

        refs = decode_ref_array(data[pos:pos + count*4], count)
        pos += count * 4

        self.classes[class_index] = {"name": name, "referents": refs}
        for ref in refs:
            self.instances[ref] = {
                "class_name": name,
                "props": {},
                "children": [],
            }

    def _parse_prop(self, data):
        pos = 0
        class_index = struct.unpack_from("<I", data, pos)[0]; pos += 4
        prop_name_len = struct.unpack_from("<I", data, pos)[0]; pos += 4
        prop_name = data[pos:pos+prop_name_len].decode("utf-8", errors="replace"); pos += prop_name_len
        prop_type = data[pos]; pos += 1

        if class_index not in self.classes:
            return
        refs = self.classes[class_index]["referents"]
        count = len(refs)

        values = self._read_prop_values(data, pos, prop_type, count)

        for i, ref in enumerate(refs):
            if ref in self.instances and i < len(values):
                self.instances[ref]["props"][prop_name] = values[i]

    def _read_prop_values(self, data, pos, prop_type, count):
        try:
            if prop_type == 0x01:  # String
                vals = []
                for _ in range(count):
                    length = struct.unpack_from("<I", data, pos)[0]; pos += 4
                    s = data[pos:pos+length].decode("utf-8", errors="replace"); pos += length
                    vals.append(s)
                return vals

            elif prop_type == 0x02:  # Bool
                return [bool(data[pos + i]) for i in range(count)]

            elif prop_type == 0x03:  # Int32
                return decode_i32_array(data[pos:pos + count*4], count)

            elif prop_type == 0x04:  # Float
                return decode_float_array(data[pos:pos + count*4], count)

            elif prop_type == 0x05:  # Double
                return [struct.unpack_from("<d", data, pos + i*8)[0] for i in range(count)]

            elif prop_type == 0x12:  # Enum
                raw = de_interleave(data[pos:pos + count*4], count)
                return [struct.unpack_from(">I", raw, i*4)[0] for i in range(count)]

            elif prop_type == 0x13:  # Ref
                return decode_ref_array(data[pos:pos + count*4], count)

            elif prop_type == 0x1C:  # SharedString
                raw = de_interleave(data[pos:pos + count*4], count)
                indices = [struct.unpack_from(">I", raw, i*4)[0] for i in range(count)]
                result = []
                for idx in indices:
                    if idx < len(self.shared_strings):
                        result.append(self.shared_strings[idx])
                    else:
                        result.append(b"")
                return result

            elif prop_type == 0x1B:  # Int64
                raw = de_interleave(data[pos:pos + count*8], count)
                vals = [struct.unpack_from(">q", raw, i*8)[0] for i in range(count)]
                return vals

        except Exception:
            pass

        return [None] * count

    def _parse_prnt(self, data):
        pos = 0
        version = data[pos]; pos += 1
        count = struct.unpack_from("<I", data, pos)[0]; pos += 4
        children = decode_ref_array(data[pos:pos + count*4], count)
        parents = decode_ref_array(data[pos + count*4:pos + count*8], count)
        for c, p in zip(children, parents):
            self.parents[c] = p

    def get_roots(self):
        return [ref for ref, parent in self.parents.items() if parent == -1]

    def get_name(self, ref):
        inst = self.instances.get(ref, {})
        return inst.get("props", {}).get("Name", f"[{inst.get('class_name','?')}]")

    def print_tree(self, ref=None, indent=0, filter_class=None, max_depth=None, depth=0):
        if max_depth is not None and depth > max_depth:
            return
        if ref is None:
            for r in self.get_roots():
                self.print_tree(r, indent, filter_class, max_depth, depth)
            return
        inst = self.instances.get(ref, {})
        cls = inst.get("class_name", "?")
        name = self.get_name(ref)
        if filter_class is None or cls == filter_class:
            print("  " * indent + f"{cls} [{name}]")
        for child in inst.get("children", []):
            self.print_tree(child, indent + 1, filter_class, max_depth, depth + 1)

    def get_scripts(self):
        script_classes = {"Script", "LocalScript", "ModuleScript"}
        scripts = []
        for ref, inst in self.instances.items():
            if inst["class_name"] in script_classes:
                name = inst["props"].get("Name", "unnamed")
                source = inst["props"].get("Source", "")
                disabled = inst["props"].get("Disabled", False)
                scripts.append({
                    "ref": ref,
                    "class": inst["class_name"],
                    "name": name,
                    "disabled": disabled,
                    "source": source,
                })
        return scripts

    def search_prop(self, prop_name):
        results = []
        for ref, inst in self.instances.items():
            if prop_name in inst["props"]:
                results.append({
                    "ref": ref,
                    "class": inst["class_name"],
                    "name": inst["props"].get("Name", "?"),
                    "value": inst["props"][prop_name],
                })
        return results


def main():
    parser = argparse.ArgumentParser(description="RBXL binary place parser")
    parser.add_argument("file", help="Path to .rbxl file")
    parser.add_argument("--tree", action="store_true", help="Print instance tree")
    parser.add_argument("--scripts", action="store_true", help="Dump script sources")
    parser.add_argument("--search", metavar="PROP", help="Search for property by name")
    parser.add_argument("--class", dest="filter_class", metavar="CLASS", help="Filter to class name")
    parser.add_argument("--grep", metavar="TEXT", help="Grep script sources")
    parser.add_argument("--depth", type=int, default=None, help="Max tree depth")
    parser.add_argument("--json", action="store_true", help="JSON output for --scripts/--search")
    args = parser.parse_args()

    p = RbxlParser(args.file)

    if args.tree:
        print("\n=== Instance Tree ===")
        p.print_tree(filter_class=args.filter_class, max_depth=args.depth)

    if args.search:
        results = p.search_prop(args.search)
        print(f"\n=== Property '{args.search}' ({len(results)} hits) ===")
        if args.json:
            print(json.dumps(results, default=str, indent=2))
        else:
            for r in results:
                print(f"  [{r['class']}] {r['name']}  =  {r['value']!r}")

    if args.scripts or args.grep:
        scripts = p.get_scripts()
        if args.grep:
            scripts = [s for s in scripts if args.grep.lower() in str(s["source"]).lower()]
        print(f"\n=== Scripts ({len(scripts)}) ===")
        for s in scripts:
            dis = " [DISABLED]" if s["disabled"] else ""
            src = s["source"]
            if isinstance(src, bytes):
                src = src.decode("utf-8", errors="replace")
            if args.json:
                print(json.dumps({"class": s["class"], "name": s["name"], "source": src}, indent=2))
            else:
                print(f"\n--- {s['class']}: {s['name']}{dis} ---")
                if src.strip():
                    print(src)
                else:
                    print("  (empty source)")

    if not any([args.tree, args.search, args.scripts, args.grep]):
        # Default: print summary
        class_counts = defaultdict(int)
        for inst in p.instances.values():
            class_counts[inst["class_name"]] += 1
        print("\n=== Class Summary ===")
        for cls, count in sorted(class_counts.items(), key=lambda x: -x[1]):
            print(f"  {count:5d}  {cls}")


if __name__ == "__main__":
    main()
