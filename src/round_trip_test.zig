// SPDX-License-Identifier: BSL-1.0

//! Out and back again, and what happens when the bytes are not what they
//! should be.
//!
//! The writer and the reader are two walks over the same type, so a round
//! trip only proves they agree with each other. The tests that matter are
//! therefore the other ones: the shapes of the bytes, and every way a file
//! can lie about what is in it.

const std = @import("std");
const testing = std.testing;

const data = @import("root.zig");

// -------------------------------------------------------------------------
// The types under test
// -------------------------------------------------------------------------

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
    shapes: []const Shape,
};

/// Encode and read straight back, and say whether it came back the same.
fn roundTrip(comptime T: type, value: T) !data.Decoded(T) {
    const bytes = try data.encodeAlloc(testing.allocator, T, value, .{});
    defer testing.allocator.free(bytes);
    return data.decode(testing.allocator, T, bytes);
}

/// A file with a payload of the caller's choosing, for the cases the writer
/// would never produce.
fn fileFor(comptime T: type, payload: []const u8, checksum: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    const gpa = testing.allocator;

    try out.appendSlice(gpa, &data.magic);
    try out.append(gpa, data.format_version);
    try out.append(gpa, if (checksum) 1 else 0);
    var fingerprint: [8]u8 = undefined;
    std.mem.writeInt(u64, &fingerprint, data.fingerprintOf(T), .little);
    try out.appendSlice(gpa, &fingerprint);
    try out.appendSlice(gpa, payload);

    if (checksum) {
        const hashing = @import("fluxion_hash");
        var crc: hashing.Crc32 = .init();
        crc.update(payload);
        var check: [4]u8 = undefined;
        std.mem.writeInt(u32, &check, crc.final(), .little);
        try out.appendSlice(gpa, &check);
    }
    return out.toOwnedSlice(gpa);
}

// -------------------------------------------------------------------------
// Out and back
// -------------------------------------------------------------------------

test "every kind of value comes back as itself" {
    var player = try roundTrip(Player, .{
        .name = "Ada",
        .level = 4096,
        .at = .{ .x = 1.5, .y = -2.25 },
        .tint = .green,
        .carrying = 7,
        .scores = .{ -1, 0, 32000 },
        .shapes = &.{ .{ .circle = 2.5 }, .{ .box = .{ .x = 3, .y = 4 } }, .{ .nothing = true } },
    });
    defer player.deinit(testing.allocator);

    try testing.expectEqualStrings("Ada", player.value.name);
    try testing.expectEqual(@as(u16, 4096), player.value.level);
    try testing.expectEqual(@as(f32, 1.5), player.value.at.x);
    try testing.expectEqual(@as(f32, -2.25), player.value.at.y);
    try testing.expectEqual(Colour.green, player.value.tint);
    try testing.expectEqual(@as(?u32, 7), player.value.carrying);
    try testing.expectEqualSlices(i16, &.{ -1, 0, 32000 }, &player.value.scores);

    try testing.expectEqual(@as(usize, 3), player.value.shapes.len);
    try testing.expectEqual(@as(f32, 2.5), player.value.shapes[0].circle);
    try testing.expectEqual(@as(f32, 4), player.value.shapes[1].box.y);
    try testing.expectEqual(true, player.value.shapes[2].nothing);
}

test "an absent optional stays absent, and an empty slice stays empty" {
    var player = try roundTrip(Player, .{
        .name = "",
        .level = 0,
        .at = .{ .x = 0, .y = 0 },
        .tint = .red,
        .carrying = null,
        .scores = .{ 0, 0, 0 },
        .shapes = &.{},
    });
    defer player.deinit(testing.allocator);

    try testing.expectEqual(@as(?u32, null), player.value.carrying);
    try testing.expectEqual(@as(usize, 0), player.value.name.len);
    try testing.expectEqual(@as(usize, 0), player.value.shapes.len);
}

test "the far ends of every number" {
    const Numbers = struct {
        a: u64,
        b: i64,
        c: u8,
        d: i8,
        e: f32,
        f: f64,
        g: u1,
        h: i128,
    };
    var read = try roundTrip(Numbers, .{
        .a = std.math.maxInt(u64),
        .b = std.math.minInt(i64),
        .c = 255,
        .d = -128,
        .e = -0.0,
        .f = std.math.floatMin(f64),
        .g = 1,
        .h = std.math.minInt(i128),
    });
    defer read.deinit(testing.allocator);

    try testing.expectEqual(std.math.maxInt(u64), read.value.a);
    try testing.expectEqual(std.math.minInt(i64), read.value.b);
    try testing.expectEqual(@as(u8, 255), read.value.c);
    try testing.expectEqual(@as(i8, -128), read.value.d);
    // Negative zero survives, because the bits are what is written.
    try testing.expectEqual(@as(u32, 0x8000_0000), @as(u32, @bitCast(read.value.e)));
    try testing.expectEqual(std.math.floatMin(f64), read.value.f);
    try testing.expectEqual(@as(u1, 1), read.value.g);
    try testing.expectEqual(std.math.minInt(i128), read.value.h);
}

test "a slice of slices, each with something in it" {
    const Lines = struct { rows: []const []const u8 };
    var read = try roundTrip(Lines, .{ .rows = &.{ "first", "", "third" } });
    defer read.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), read.value.rows.len);
    try testing.expectEqualStrings("first", read.value.rows[0]);
    try testing.expectEqualStrings("", read.value.rows[1]);
    try testing.expectEqualStrings("third", read.value.rows[2]);
}

test "a type with nothing to allocate needs no allocator" {
    const Packet = struct { kind: Colour, at: Point, live: bool };
    const bytes = try data.encodeAlloc(testing.allocator, Packet, .{
        .kind = .blue,
        .at = .{ .x = 9, .y = 8 },
        .live = true,
    }, .{});
    defer testing.allocator.free(bytes);

    // No allocator anywhere in this call, which is what makes the format
    // usable in a place that has not got one.
    const read = try data.decodeFixed(Packet, bytes);
    try testing.expectEqual(Colour.blue, read.kind);
    try testing.expectEqual(@as(f32, 9), read.at.x);
    try testing.expect(read.live);
}

// -------------------------------------------------------------------------
// The bytes themselves
// -------------------------------------------------------------------------

test "the header says what it is, which version, and which schema" {
    const bytes = try data.encodeAlloc(testing.allocator, Point, .{ .x = 1, .y = 2 }, .{});
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, &data.magic, bytes[0..4]);
    try testing.expectEqual(data.format_version, bytes[4]);
    try testing.expectEqual(@as(u8, 1), bytes[5]); // a checksum follows
    try testing.expectEqual(data.fingerprintOf(Point), std.mem.readInt(u64, bytes[6..14], .little));

    // Two floats and a CRC after the header, and nothing else.
    try testing.expectEqual(data.header_size + 8 + 4, bytes.len);
}

test "a small number costs one byte and a large one costs what it must" {
    const One = struct { n: u64 };
    for ([_]struct { value: u64, payload: usize }{
        .{ .value = 0, .payload = 1 },
        .{ .value = 127, .payload = 1 },
        .{ .value = 128, .payload = 2 },
        .{ .value = 300, .payload = 2 },
        .{ .value = std.math.maxInt(u64), .payload = 10 },
    }) |case| {
        const bytes = try data.encodeAlloc(testing.allocator, One, .{ .n = case.value }, .{ .checksum = false });
        defer testing.allocator.free(bytes);
        try testing.expectEqual(data.header_size + case.payload, bytes.len);
    }
}

test "a signed number close to zero is small whichever side it is on" {
    const One = struct { n: i32 };
    for ([_]i32{ 0, -1, 1, -64, 63 }) |value| {
        const bytes = try data.encodeAlloc(testing.allocator, One, .{ .n = value }, .{ .checksum = false });
        defer testing.allocator.free(bytes);
        try testing.expectEqual(data.header_size + 1, bytes.len);
    }
    // Zigzag doubles the magnitude before the varint sees it, so seven bits
    // hold the range -64 to 63 and the next one either way needs two.
    for ([_]i32{ 64, -65 }) |value| {
        const bytes = try data.encodeAlloc(testing.allocator, One, .{ .n = value }, .{ .checksum = false });
        defer testing.allocator.free(bytes);
        try testing.expectEqual(data.header_size + 2, bytes.len);
    }
}

test "the checksum can be left off, and then there is nothing after the payload" {
    const with = try data.encodeAlloc(testing.allocator, Point, .{ .x = 1, .y = 2 }, .{});
    defer testing.allocator.free(with);
    const without = try data.encodeAlloc(testing.allocator, Point, .{ .x = 1, .y = 2 }, .{ .checksum = false });
    defer testing.allocator.free(without);

    try testing.expectEqual(with.len - 4, without.len);
    try testing.expectEqual(@as(u8, 0), without[5]);
    // And a file written without one reads back without complaint.
    const read = try data.decodeFixed(Point, without);
    try testing.expectEqual(@as(f32, 2), read.y);
}

// -------------------------------------------------------------------------
// Which schema a file holds
// -------------------------------------------------------------------------

test "a file says which type it holds, without being decoded" {
    const bytes = try data.encodeAlloc(testing.allocator, Player, .{
        .name = "x",
        .level = 1,
        .at = .{ .x = 0, .y = 0 },
        .tint = .red,
        .carrying = null,
        .scores = .{ 0, 0, 0 },
        .shapes = &.{},
    }, .{});
    defer testing.allocator.free(bytes);

    try testing.expectEqual(data.fingerprintOf(Player), try data.schemaOf(bytes));
    try testing.expect(try data.schemaOf(bytes) != data.fingerprintOf(Point));
}

test "reading a file as the wrong type is refused, and migration is a switch" {
    // Version one of a save file.
    const SaveV1 = struct { level: u16, name: []const u8 };
    // Version two, with a field added - a different type, and so a
    // different number in the header.
    const SaveV2 = struct { level: u16, name: []const u8, lives: u8 };

    const old = try data.encodeAlloc(testing.allocator, SaveV1, .{ .level = 3, .name = "Ada" }, .{});
    defer testing.allocator.free(old);

    // Asking for the new type gets a refusal rather than a plausible mess.
    try testing.expectError(data.Error.SchemaMismatch, data.decode(testing.allocator, SaveV2, old));

    // And this is the whole of migration.
    const held = try data.schemaOf(old);
    var upgraded: SaveV2 = undefined;
    if (held == data.fingerprintOf(SaveV2)) {
        var read = try data.decode(testing.allocator, SaveV2, old);
        defer read.deinit(testing.allocator);
        upgraded = read.value;
    } else if (held == data.fingerprintOf(SaveV1)) {
        var read = try data.decode(testing.allocator, SaveV1, old);
        defer read.deinit(testing.allocator);
        upgraded = .{ .level = read.value.level, .name = "", .lives = 3 };
    } else {
        return error.UnknownSchema;
    }

    try testing.expectEqual(@as(u16, 3), upgraded.level);
    try testing.expectEqual(@as(u8, 3), upgraded.lives);
}

// -------------------------------------------------------------------------
// What it refuses
// -------------------------------------------------------------------------

test "a file that is not one" {
    try testing.expectError(data.Error.NotFluxionData, data.schemaOf("short"));
    try testing.expectError(data.Error.NotFluxionData, data.schemaOf(&[_]u8{0} ** 32));

    const wrong_version = try fileFor(Point, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, false);
    defer testing.allocator.free(wrong_version);
    wrong_version[4] = 99;
    try testing.expectError(data.Error.UnsupportedVersion, data.schemaOf(wrong_version));
}

test "a payload that was damaged after it was written" {
    const bytes = try data.encodeAlloc(testing.allocator, Point, .{ .x = 1, .y = 2 }, .{});
    defer testing.allocator.free(bytes);

    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    copy[data.header_size] ^= 0xFF;

    try testing.expectError(data.Error.BadChecksum, data.decode(testing.allocator, Point, copy));
    // Without a checksum the same damage is a different float and nothing
    // says so, which is what the checksum is for.
    const unchecked = try data.encodeAlloc(testing.allocator, Point, .{ .x = 1, .y = 2 }, .{ .checksum = false });
    defer testing.allocator.free(unchecked);
    const bent = try testing.allocator.dupe(u8, unchecked);
    defer testing.allocator.free(bent);
    bent[data.header_size] ^= 0xFF;
    const read = try data.decodeFixed(Point, bent);
    try testing.expect(read.x != 1);
}

test "a payload that stops in the middle" {
    const bytes = try data.encodeAlloc(testing.allocator, Point, .{ .x = 1, .y = 2 }, .{ .checksum = false });
    defer testing.allocator.free(bytes);
    try testing.expectError(data.Error.Truncated, data.decode(testing.allocator, Point, bytes[0 .. bytes.len - 3]));
}

test "a length longer than the bytes that are left" {
    const Names = struct { names: []const []const u8 };
    // A varint of 0xFFFF_FFFF, and then nothing to fill it with.
    const file = try fileFor(Names, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }, false);
    defer testing.allocator.free(file);
    try testing.expectError(data.Error.TooManyElements, data.decode(testing.allocator, Names, file));

    // And the same for a string, where each element is one byte.
    const One = struct { text: []const u8 };
    const text = try fileFor(One, &.{ 0x80, 0x02, 'a', 'b' }, false);
    defer testing.allocator.free(text);
    try testing.expectError(data.Error.TooManyElements, data.decode(testing.allocator, One, text));
}

test "a value no member of that type has" {
    const One = struct { tint: Colour };
    // Colour has three members, so seven is not one of them.
    const bad_enum = try fileFor(One, &.{7}, false);
    defer testing.allocator.free(bad_enum);
    try testing.expectError(data.Error.BadEnum, data.decode(testing.allocator, One, bad_enum));

    const Held = struct { shape: Shape };
    // Shape has three arms, so arm nine is not one of them.
    const bad_union = try fileFor(Held, &.{ 9, 0 }, false);
    defer testing.allocator.free(bad_union);
    try testing.expectError(data.Error.BadUnion, data.decode(testing.allocator, Held, bad_union));

    const Flag = struct { on: bool };
    const bad_bool = try fileFor(Flag, &.{2}, false);
    defer testing.allocator.free(bad_bool);
    try testing.expectError(data.Error.BadBool, data.decode(testing.allocator, Flag, bad_bool));
}

test "a number too wide for the type it is being read into" {
    const Small = struct { n: u16 };
    // A varint spelling a value past sixteen bits.
    const too_big = try fileFor(Small, &.{ 0xFF, 0xFF, 0xFF, 0x0F }, false);
    defer testing.allocator.free(too_big);
    try testing.expectError(data.Error.Overflow, data.decode(testing.allocator, Small, too_big));
}

test "a read that fails part of the way through frees what it had allocated" {
    // Two strings, the second of which claims more than is there. The first
    // was allocated before the second failed, and the testing allocator is
    // what checks that it was given back.
    const Pair = struct { first: []const u8, second: []const u8 };
    const file = try fileFor(Pair, &.{ 3, 'a', 'b', 'c', 0x7F }, false);
    defer testing.allocator.free(file);
    try testing.expectError(data.Error.TooManyElements, data.decode(testing.allocator, Pair, file));
}

/// Many fields with long names: a long description to hash, and many to
/// read one after another.
const Wide = struct {
    a_field_with_a_rather_long_name_00: f32 = 0,
    a_field_with_a_rather_long_name_01: f32 = 1,
    a_field_with_a_rather_long_name_02: f32 = 2,
    a_field_with_a_rather_long_name_03: f32 = 3,
    a_field_with_a_rather_long_name_04: f32 = 4,
    a_field_with_a_rather_long_name_05: f32 = 5,
    a_field_with_a_rather_long_name_06: f32 = 6,
    a_field_with_a_rather_long_name_07: f32 = 7,
    a_field_with_a_rather_long_name_08: f32 = 8,
    a_field_with_a_rather_long_name_09: f32 = 9,
    a_field_with_a_rather_long_name_10: f32 = 10,
    a_field_with_a_rather_long_name_11: f32 = 11,
    a_field_with_a_rather_long_name_12: f32 = 12,
    a_field_with_a_rather_long_name_13: f32 = 13,
    a_field_with_a_rather_long_name_14: f32 = 14,
    a_field_with_a_rather_long_name_15: f32 = 15,
    a_field_with_a_rather_long_name_16: f32 = 16,
    a_field_with_a_rather_long_name_17: f32 = 17,
    a_field_with_a_rather_long_name_18: f32 = 18,
    a_field_with_a_rather_long_name_19: f32 = 19,
    a_field_with_a_rather_long_name_20: f32 = 20,
    a_field_with_a_rather_long_name_21: f32 = 21,
    a_field_with_a_rather_long_name_22: f32 = 22,
    a_field_with_a_rather_long_name_23: f32 = 23,
    a_field_with_a_rather_long_name_24: f32 = 24,
    a_field_with_a_rather_long_name_25: f32 = 25,
    a_field_with_a_rather_long_name_26: f32 = 26,
    a_field_with_a_rather_long_name_27: f32 = 27,
    a_field_with_a_rather_long_name_28: f32 = 28,
    a_field_with_a_rather_long_name_29: f32 = 29,
    a_field_with_a_rather_long_name_30: f32 = 30,
    a_field_with_a_rather_long_name_31: f32 = 31,
    a_field_with_a_rather_long_name_32: f32 = 32,
    a_field_with_a_rather_long_name_33: f32 = 33,
    a_field_with_a_rather_long_name_34: f32 = 34,
    a_field_with_a_rather_long_name_35: f32 = 35,
    a_field_with_a_rather_long_name_36: f32 = 36,
    a_field_with_a_rather_long_name_37: f32 = 37,
    a_field_with_a_rather_long_name_38: f32 = 38,
    a_field_with_a_rather_long_name_39: f32 = 39,
    a_field_with_a_rather_long_name_40: f32 = 40,
    a_field_with_a_rather_long_name_41: f32 = 41,
    a_field_with_a_rather_long_name_42: f32 = 42,
    a_field_with_a_rather_long_name_43: f32 = 43,
    a_field_with_a_rather_long_name_44: f32 = 44,
    a_field_with_a_rather_long_name_45: f32 = 45,
    a_field_with_a_rather_long_name_46: f32 = 46,
    a_field_with_a_rather_long_name_47: f32 = 47,
    last: []const u8 = "",
};

test "a type of many fields is described, known and read back" {
    var read = try roundTrip(Wide, .{ .a_field_with_a_rather_long_name_47 = 7, .last = "end" });
    defer read.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 7), read.value.a_field_with_a_rather_long_name_47);
    try testing.expectEqual(@as(f32, 3), read.value.a_field_with_a_rather_long_name_03);
    try testing.expectEqualStrings("end", read.value.last);
    try testing.expect(data.fingerprintOf(Wide) != data.fingerprintOf(Player));
}

test "an arena is the other way, and needs no deinit at all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const bytes = try data.encodeAlloc(testing.allocator, Player, .{
        .name = "Grace",
        .level = 9,
        .at = .{ .x = 1, .y = 1 },
        .tint = .blue,
        .carrying = 2,
        .scores = .{ 1, 2, 3 },
        .shapes = &.{.{ .circle = 1 }},
    }, .{});
    defer testing.allocator.free(bytes);

    // No `deinit` on the result: the arena has it.
    const read = try data.decode(arena.allocator(), Player, bytes);
    try testing.expectEqualStrings("Grace", read.value.name);
}

test "a packed struct goes out as its number and comes back as itself" {
    const Handle = packed struct(u64) { index: u32, generation: u32 };
    const Flags = packed struct(u8) { visible: bool, solid: bool, rest: u6 };
    const Held = struct { who: Handle, how: Flags, many: [2]Handle };

    var read = try roundTrip(Held, .{
        .who = .{ .index = 7, .generation = 3 },
        .how = .{ .visible = true, .solid = false, .rest = 0b101010 },
        .many = .{ .{ .index = 1, .generation = 1 }, .{ .index = 0, .generation = 0 } },
    });
    defer read.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 7), read.value.who.index);
    try testing.expectEqual(@as(u32, 3), read.value.who.generation);
    try testing.expect(read.value.how.visible);
    try testing.expect(!read.value.how.solid);
    try testing.expectEqual(@as(u6, 0b101010), read.value.how.rest);
    try testing.expectEqual(@as(u32, 1), read.value.many[0].index);
    try testing.expectEqual(@as(u32, 0), read.value.many[1].generation);
}

test "a packed struct costs what its number costs, not what its fields do" {
    const Small = packed struct(u64) { index: u32, generation: u32 };
    const One = struct { it: Small };

    // Two small numbers in a packed u64 is one varint of the whole u64, and
    // that number is large - which is the trade a packed struct makes.
    const zero = try data.encodeAlloc(testing.allocator, One, .{
        .it = .{ .index = 0, .generation = 0 },
    }, .{ .checksum = false });
    defer testing.allocator.free(zero);
    try testing.expectEqual(data.header_size + 1, zero.len);
}

/// Many fields that are structs of their own: a light with its colours.
const Tint = struct { r: f32 = 1, g: f32 = 1, b: f32 = 1, a: f32 = 1 };
const Deep = struct {
    colour_00: Tint = .{},
    colour_01: Tint = .{},
    colour_02: Tint = .{},
    colour_03: Tint = .{},
    colour_04: Tint = .{},
    colour_05: Tint = .{},
    colour_06: Tint = .{},
    colour_07: Tint = .{},
    colour_08: Tint = .{},
    colour_09: Tint = .{},
    colour_10: Tint = .{},
    colour_11: Tint = .{},
    colour_12: Tint = .{},
    colour_13: Tint = .{},
    colour_14: Tint = .{},
    colour_15: Tint = .{},
    colour_16: Tint = .{},
    colour_17: Tint = .{},
    colour_18: Tint = .{},
    colour_19: Tint = .{},
    colour_20: Tint = .{},
    colour_21: Tint = .{},
    colour_22: Tint = .{},
    colour_23: Tint = .{},
    colour_24: Tint = .{},
    colour_25: Tint = .{},
    colour_26: Tint = .{},
    colour_27: Tint = .{},
    colour_28: Tint = .{},
    colour_29: Tint = .{},
    colour_30: Tint = .{},
    colour_31: Tint = .{},
    colour_32: Tint = .{},
    colour_33: Tint = .{},
    colour_34: Tint = .{},
    colour_35: Tint = .{},
    colour_36: Tint = .{},
    colour_37: Tint = .{},
    colour_38: Tint = .{},
    colour_39: Tint = .{},
};

test "a type of many fields that are structs is walked without running out of branches" {
    // In one evaluation, at the compiler's own quota, as a caller that does
    // not raise it asks.
    const answers = comptime .{ data.schema.allocates(Deep), data.schema.minimumSize(Deep) };
    try testing.expect(!answers[0]);
    try testing.expectEqual(@as(usize, 40 * 4 * 4), answers[1]);
}
