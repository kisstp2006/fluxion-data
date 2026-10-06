// SPDX-License-Identifier: BSL-1.0

//! What a type is, written down at compile time.
//!
//! Two things come out of walking a Zig type: a canonical description of it,
//! and a number that stands for that description. The number goes in the
//! file; the description is what a person reads when the two do not match.
//!
//! ```zig
//! schema.describe(Player)      // "struct{name:[]u8,level:u16,at:struct{x:f32,y:f32}}"
//! schema.fingerprint(Player)   // 0x8f3a…
//! ```
//!
//! **The names are in it, not only the shapes.** Two structs of three floats
//! are the same bytes and not the same thing, and a file written when the
//! second field was called `y` should not be read into one where it is called
//! `z`. Renaming a field changes the fingerprint, which is the point: the
//! format has no field names in it at all, so the only chance to notice is
//! here.
//!
//! **What it refuses, it refuses at compile time**, with a message naming the
//! type. A pointer is the whole of it: a single-item pointer is a graph, a
//! graph has cycles, and a format that followed one would either loop or
//! quietly write the same thing twice. Slices are fine - they are a length
//! and elements - and everything else a program puts in a file is fine.

const std = @import("std");
const hashing = @import("fluxion_hash");

/// The canonical description of `T`, as a string built at compile time.
///
/// The grammar is small on purpose. It says what the wire format will do and
/// nothing else, so two types describe the same way exactly when they encode
/// the same way.
pub fn describe(comptime T: type) []const u8 {
    comptime check(T);
    return comptime written(T);
}

/// The number a description is known by, which is what goes in the file.
///
/// Sixty-four bits of xxHash over `describe`. A collision would mean reading
/// one type's bytes as another's, which is why it is sixty-four and not
/// thirty-two.
pub fn fingerprint(comptime T: type) u64 {
    return comptime blk: {
        const text = describe(T);
        // The hash walks the description a few bytes at a time, and a type
        // of many fields has a long one.
        @setEvalBranchQuota(1000 + 64 * text.len);
        break :blk hashing.hashBytes(text);
    };
}

/// How many backward branches walking a type may take. Every field is a
/// turn of a loop, and a struct of structs - a light with its colours - is
/// many; the compiler's own thousand counts every walk in the evaluation that
/// asked, so a caller several types deep would run out wherever it was
/// asked first. A walk raises it for the evaluation it is in.
const walk_quota = 100_000;

/// Does reading a `T` need an allocator? False when nothing in it is a
/// slice, which is most configuration and every packet of fixed shape.
pub fn allocates(comptime T: type) bool {
    @setEvalBranchQuota(walk_quota);
    comptime check(T);
    return comptime switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => false,
        .optional => |o| allocates(o.child),
        .array => |a| allocates(a.child),
        .pointer => true,
        .@"struct" => |s| blk: {
            if (s.layout == .@"packed") break :blk false;
            for (s.fields) |field| {
                if (allocates(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |u| blk: {
            for (u.fields) |field| {
                if (allocates(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => unreachable,
    };
}

/// The fewest bytes a `T` can occupy, which is what makes a length longer
/// than the bytes left provably wrong. Zero only for a type with nothing in
/// it at all.
pub fn minimumSize(comptime T: type) usize {
    @setEvalBranchQuota(walk_quota);
    comptime check(T);
    return comptime switch (@typeInfo(T)) {
        .bool => 1,
        // A float is written whole: no varint would make it shorter.
        .float => |f| f.bits / 8,
        // A varint is one byte when the number is small, and often is.
        .int, .@"enum" => 1,
        // A byte says whether anything follows.
        .optional => 1,
        .array => |a| a.len * minimumSize(a.child),
        // A varint length of zero.
        .pointer => 1,
        .@"struct" => |s| blk: {
            if (s.layout == .@"packed") break :blk minimumSize(s.backing_integer.?);
            var total: usize = 0;
            for (s.fields) |field| total += minimumSize(field.type);
            break :blk total;
        },
        .@"union" => |u| blk: {
            // The tag, and then the smallest arm.
            var smallest: usize = std.math.maxInt(usize);
            for (u.fields) |field| smallest = @min(smallest, minimumSize(field.type));
            break :blk 1 + smallest;
        },
        else => unreachable,
    };
}

// -------------------------------------------------------------------------
// Walking a type
// -------------------------------------------------------------------------

/// Refuse, at compile time, everything the format cannot carry.
pub fn check(comptime T: type) void {
    comptime {
        @setEvalBranchQuota(walk_quota);
        switch (@typeInfo(T)) {
            .bool => {},
            .float => |f| {
                if (f.bits != 16 and f.bits != 32 and f.bits != 64) {
                    refuse(T, "only 16, 32 and 64 bit floats are written; the wider ones are a different number on every machine");
                }
            },
            .int => |i| {
                if (i.bits == 0) refuse(T, "an integer of no bits carries nothing");
                if (i.bits > 128) refuse(T, "integers wider than 128 bits are not written");
            },
            .@"enum" => |e| {
                if (!e.is_exhaustive) {
                    refuse(T, "a non-exhaustive enum has values it does not name, and a file cannot say which");
                }
                check(e.tag_type);
            },
            .optional => |o| {
                switch (@typeInfo(o.child)) {
                    .optional => refuse(T, "an optional optional has two ways to say nothing and one way to write it"),
                    .pointer => refuse(T, "an optional slice and an empty one are the same file; use the empty one"),
                    else => {},
                }
                check(o.child);
            },
            .array => |a| check(a.child),
            .pointer => |p| {
                if (p.size != .slice) {
                    refuse(T, "only a slice is written: a single-item pointer is a graph, and a graph has cycles a file cannot hold");
                }
                if (p.sentinel() != null) {
                    refuse(T, "a sentinel is a property of the memory, not of the value; write the slice without one");
                }
                check(p.child);
            },
            .@"struct" => |s| blk: {
                if (s.layout == .@"packed") {
                    // A packed struct is a number wearing a hat, and the
                    // number is what gets written. Zig fixes the bit layout -
                    // first field in the low bits - so the number is the same
                    // on every machine, which is all this format asks of a
                    // type. Refusing them would only mean every caller
                    // writing the `@bitCast` by hand.
                    check(s.backing_integer.?);
                    break :blk;
                }
                for (s.fields) |field| {
                    if (field.is_comptime) refuse(T, "a comptime field is not in the value, so it cannot be in the file");
                    check(field.type);
                }
                break :blk;
            },
            .@"union" => |u| {
                if (u.tag_type == null) {
                    refuse(T, "an untagged union does not know which arm it is holding, and neither would a reader");
                }
                for (u.fields) |field| check(field.type);
            },
            .void => refuse(T, "there is nothing to write"),
            else => refuse(T, "this is not a kind of value a file holds"),
        }
    }
}

fn refuse(comptime T: type, comptime why: []const u8) noreturn {
    @compileError("fluxion-data: " ++ @typeName(T) ++ ": " ++ why);
}

fn written(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "bool",
        .int => |i| (if (i.signedness == .signed) "i" else "u") ++ digits(i.bits),
        .float => |f| "f" ++ digits(f.bits),
        .@"enum" => |e| blk: {
            var out: []const u8 = "enum(" ++ written(e.tag_type) ++ "){";
            for (e.fields, 0..) |field, i| {
                if (i > 0) out = out ++ ",";
                out = out ++ field.name;
            }
            break :blk out ++ "}";
        },
        .optional => |o| "?" ++ written(o.child),
        .array => |a| "[" ++ digits(a.len) ++ "]" ++ written(a.child),
        .pointer => |p| "[]" ++ written(p.child),
        .@"struct" => |s| blk: {
            if (s.layout == .@"packed") {
                var out: []const u8 = "packed(" ++ written(s.backing_integer.?) ++ "){";
                for (s.fields, 0..) |field, i| {
                    if (i > 0) out = out ++ ",";
                    out = out ++ field.name ++ ":" ++ written(field.type);
                }
                break :blk out ++ "}";
            }
            var out: []const u8 = "struct{";
            for (s.fields, 0..) |field, i| {
                if (i > 0) out = out ++ ",";
                out = out ++ field.name ++ ":" ++ written(field.type);
            }
            break :blk out ++ "}";
        },
        .@"union" => |u| blk: {
            var out: []const u8 = "union{";
            for (u.fields, 0..) |field, i| {
                if (i > 0) out = out ++ ",";
                out = out ++ field.name ++ ":" ++ written(field.type);
            }
            break :blk out ++ "}";
        },
        else => unreachable,
    };
}

fn digits(comptime n: usize) []const u8 {
    if (n == 0) return "0";
    var out: []const u8 = "";
    var left = n;
    while (left > 0) : (left /= 10) {
        out = [_]u8{'0' + @as(u8, @intCast(left % 10))} ++ out;
    }
    return out;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

const Point = struct { x: f32, y: f32 };
const Colour = enum(u8) { red, green, blue };
const Shape = union(enum) { circle: f32, box: Point, nothing: bool };

const Player = struct {
    name: []const u8,
    level: u16,
    at: Point,
    tint: Colour,
    carrying: ?u32,
    scores: [3]i16,
};

test "a description says what the format will do" {
    try testing.expectEqualStrings("u16", describe(u16));
    try testing.expectEqualStrings("i7", describe(i7));
    try testing.expectEqualStrings("f64", describe(f64));
    try testing.expectEqualStrings("bool", describe(bool));
    try testing.expectEqualStrings("struct{x:f32,y:f32}", describe(Point));
    try testing.expectEqualStrings("enum(u8){red,green,blue}", describe(Colour));
    try testing.expectEqualStrings("union{circle:f32,box:struct{x:f32,y:f32},nothing:bool}", describe(Shape));
    try testing.expectEqualStrings("?u32", describe(?u32));
    try testing.expectEqualStrings("[3]i16", describe([3]i16));
    try testing.expectEqualStrings("[]u8", describe([]const u8));
    try testing.expectEqualStrings(
        "struct{name:[]u8,level:u16,at:struct{x:f32,y:f32},tint:enum(u8){red,green,blue},carrying:?u32,scores:[3]i16}",
        describe(Player),
    );
}

test "constness is not part of the value" {
    // A `[]u8` and a `[]const u8` hold the same bytes and describe the same
    // way, because what may be written to is a property of the memory rather
    // than of what is in it.
    try testing.expectEqual(fingerprint([]u8), fingerprint([]const u8));
}

test "the fingerprint moves when the meaning does" {
    const Swapped = struct { y: f32, x: f32 };
    const Renamed = struct { x: f32, z: f32 };
    const Widened = struct { x: f64, y: f64 };
    const Same = struct { x: f32, y: f32 };

    try testing.expectEqual(fingerprint(Point), fingerprint(Same));
    // Two fields of three floats each, swapped: the same bytes, a different
    // meaning, and a different number.
    try testing.expect(fingerprint(Point) != fingerprint(Swapped));
    try testing.expect(fingerprint(Point) != fingerprint(Renamed));
    try testing.expect(fingerprint(Point) != fingerprint(Widened));

    // And an enum whose members were reordered.
    const Reordered = enum(u8) { green, red, blue };
    try testing.expect(fingerprint(Colour) != fingerprint(Reordered));
}

test "which types need an allocator to read" {
    try testing.expect(!allocates(u32));
    try testing.expect(!allocates(Point));
    try testing.expect(!allocates([4]Colour));
    try testing.expect(!allocates(?Point));
    try testing.expect(allocates([]const u8));
    try testing.expect(allocates(Player));
    try testing.expect(allocates(struct { a: u8, b: []const f32 }));
    try testing.expect(allocates(union(enum) { one: u8, many: []const u8 }));
}

test "the smallest a value can be" {
    // A varint is one byte when the number is small, whatever its type.
    try testing.expectEqual(@as(usize, 1), minimumSize(u64));
    try testing.expectEqual(@as(usize, 1), minimumSize(bool));
    // A float is written whole, so two of them are eight bytes and never
    // fewer.
    try testing.expectEqual(@as(usize, 8), minimumSize(Point));
    // An empty slice is one byte of length.
    try testing.expectEqual(@as(usize, 1), minimumSize([]const u8));
    // A tag, and then the smallest arm - which is the bool.
    try testing.expectEqual(@as(usize, 2), minimumSize(Shape));
    try testing.expectEqual(@as(usize, 3), minimumSize([3]i16));
}

test "a fingerprint is the same number every time it is asked for" {
    // Not a tautology: it is built by walking a type at compile time, and a
    // walk that depended on anything else would produce a file that a second
    // build could not read.
    try testing.expectEqual(fingerprint(Player), fingerprint(Player));
    try testing.expectEqual(hashing.hashBytes(describe(Player)), fingerprint(Player));
}

test "a packed struct is described by its bits, not confused with them" {
    const Flags = packed struct(u8) { visible: bool, solid: bool, rest: u6 };
    const Handle = packed struct(u64) { index: u32, generation: u32 };

    try testing.expectEqualStrings("packed(u8){visible:bool,solid:bool,rest:u6}", describe(Flags));
    try testing.expectEqualStrings("packed(u64){index:u32,generation:u32}", describe(Handle));

    // The number behind it is not the same type, and does not read as one.
    try testing.expect(fingerprint(Flags) != fingerprint(u8));
    try testing.expect(fingerprint(Handle) != fingerprint(u64));

    // It owns nothing, and it costs what its number costs.
    try testing.expect(!allocates(Flags));
    try testing.expectEqual(minimumSize(u64), minimumSize(Handle));
}
