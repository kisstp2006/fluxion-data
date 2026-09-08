# Fluxion Data

A type, written down and read back. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `schema` | What a type is, at compile time: its canonical description, and the number that stands for it. |
| `write` | A value into bytes. |
| `read` | Bytes back into a value, believing none of the lengths in them. |

```zig
const data = @import("fluxion_data");

const Save = struct {
    name: []const u8,
    level: u16,
    at: struct { x: f32, y: f32 },
    bag: []const Item,
};

try data.writeFile(gpa, io, "save.fxdt", Save, save, .{});

var loaded = try data.readFile(gpa, io, "save.fxdt", Save, .limited64(1 << 20));
defer loaded.deinit(gpa);
loaded.value.level == save.level;
```

**The schema is the type.** There is nothing to declare, nothing to generate,
and no second description to keep in step. `describe` walks the Zig type at
compile time and `fingerprint` is that description hashed, so the save above
is:

```
struct{name:[]u8,level:u16,at:struct{x:f32,y:f32},bag:[]union{coin:u32,key:[]u8,nothing:bool}}
```

Reorder two fields, widen an integer, rename a member, and the number changes
with it. The names are in the description because two structs of three floats
are the same bytes and not the same thing, and the format itself has no field
names in it at all - so this is the only chance to notice.

**Which makes migration a `switch`, not a mechanism.** Every file says which
schema it holds, and `schemaOf` reads that without decoding a byte:

```zig
const held = try data.schemaOf(bytes);
if (held == data.fingerprintOf(SaveV2)) {
    ...
} else if (held == data.fingerprintOf(SaveV1)) {
    // read the old one, and convert
}
```

The alternative - a version number the programmer remembers to bump - is a
number that is right until the once it is not, and that once is a file read as
something it is not.

**There is no text half, and that is deliberate.** Zig ships `std.zon` and
`std.json`, both good, and `.zon` is already the language every manifest in
this family is written in. What neither gives is a compact binary form with a
version on it, so that is what this is. Human-editable data belongs in `.zon`;
this is the format for shipping. The demo's save is 61 bytes here and 238 as a
`.zon` literal.

**A type with no slice in it needs no allocator.** `decodeFixed` takes none,
and is a compile error for a type that would have needed one - rather than an
allocator parameter that is sometimes ignored and a caller who cannot tell
which.

```zig
const settings = try data.decodeFixed(Settings, bytes); // twenty bytes, no allocator
```

## What is in a file

| | |
| --- | --- |
| `FXDT` | four bytes, so a file that is not one is noticed at once |
| version | one byte: the container's own, which is not the schema's |
| flags | one byte, of which one bit is in use: whether a checksum follows |
| fingerprint | eight bytes, little endian: which type this holds |
| payload | the value |
| checksum | four bytes of CRC-32 over the payload, unless turned off |

Fourteen bytes of header, and the checksum is over the payload alone so the
header can be read without having the rest.

The payload is what the type says and nothing else. A `bool` is one byte, an
integer of eight bits or fewer is one byte, a wider one is a varint and a
signed one is zigzagged first, so small numbers near zero are one byte
whichever side they are on. A float is written whole, little endian, because
no varint would make it shorter. A slice is a length and then its elements,
and a string is a length and then its bytes. A struct is its fields in order.
A union is which arm, and then that arm.

## What it refuses

At compile time, with a message naming the type: a single-item pointer, which
is a graph and a graph has cycles; a sentinel, which is a property of the
memory rather than of the value; an untagged union, which does not know what
it is holding; a packed struct, which is a number wearing a hat; an optional
slice, because an absent one and an empty one would be the same file; a
non-exhaustive enum, which has values it does not name.

At run time, from a file this program did not write: a length longer than the
bytes that are left, before a single element is allocated; a number no member
of that enum has; an arm the union has not got; a byte that is neither zero
nor one where a `bool` was written; a varint carrying more bits than its type
holds. A read that fails part of the way through gives back everything it had
allocated.

Nothing here allocates except through the allocator it is handed. What
`encode` takes it borrows; what `decode` returns it owns, until `deinit` - or
until an arena is dropped, if that is what it was decoded into.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-data
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_data = .{ .path = "../fluxion-data" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_data", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_data", fluxion.module("fluxion_data"));
```

```zig
const data = @import("fluxion_data");
```

Two dependencies come with it, fetched the same way and needing nothing from
you: [Fluxion Encoding](https://github.com/kisstp2006/fluxion-encoding), whose
varints keep a small number small, and
[Fluxion Hash](https://github.com/kisstp2006/fluxion-hash), whose xxHash is
the fingerprint and whose CRC-32 is the checksum.

## Where it sits

The second tier of the Fluxion licence ladder: `BSL-1.0`, built on two
tier-one libraries. That tier asks nothing of a binary built from it - no
notice in an about-box, no file shipped alongside - which is what a format
every other layer writes its files in should ask.

## The tests

A round trip only proves the writer and the reader agree with each other, so
most of the suite is the other thing: the shapes of the bytes, and every way a
file can lie about what is in it. A varint that should be one byte and is; a
zigzag boundary at -64 and 63; a header read field by field; a schema mismatch;
a flipped bit caught by the checksum, and the same bit not caught when the
checksum was turned off. Files are built by hand for the cases no writer would
produce - a length of four billion, an enum value of seven where there are
three members, a union arm nine - and the allocator the tests run on is the one
that fails a test that leaks.

## Build

```bash
zig build test        # run the test suite
zig build example     # save a game, load it, and migrate an older save
zig build docs        # generate API docs into zig-out/docs
```

## Licence

`BSL-1.0`. See [LICENSE](LICENSE).
