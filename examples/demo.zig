// SPDX-License-Identifier: BSL-1.0

//! A tour of Fluxion Data. Run it with `zig build example`.
//!
//! It saves a game, reads it back off the disk, then does the three things a
//! save format exists to do: notice a file written by an older build, refuse
//! one that was damaged, and read a fixed-shape record without an allocator.

const std = @import("std");
const Io = std.Io;
const data = @import("fluxion_data");

// -------------------------------------------------------------------------
// What we are saving
// -------------------------------------------------------------------------

const Point = struct { x: f32, y: f32 };

const Item = union(enum) {
    coin: u32,
    key: []const u8,
    nothing: bool,
};

/// The save file as this build knows it.
const Save = struct {
    name: []const u8,
    level: u16,
    at: Point,
    lives: u8,
    // Not `?[]const u8`: an absent checkpoint and an empty one would be the
    // same file, so the schema refuses the optional at compile time and the
    // empty slice is the one way to say it.
    checkpoint: []const u8,
    bag: []const Item,
};

/// The save file as an older build knew it: no `lives`, and no bag.
const SaveV1 = struct {
    name: []const u8,
    level: u16,
    at: Point,
};

/// Nothing in it is a slice, so reading it needs no allocator at all.
const Settings = struct {
    volume: f32,
    fullscreen: bool,
    difficulty: enum(u8) { easy, normal, hard },
};

const save_path = "zig-out/demo-save.fxdt";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout.interface;

    // --- what a type is -------------------------------------------------

    try out.print("--- the schema is the type ---\n", .{});
    try out.print("{s}\n", .{data.describe(Save)});
    try out.print("fingerprint 0x{x:0>16}\n\n", .{data.fingerprintOf(Save)});

    // --- save -----------------------------------------------------------

    const save: Save = .{
        .name = "Ada",
        .level = 7,
        .at = .{ .x = 128.5, .y = -32.25 },
        .lives = 3,
        .checkpoint = "the long bridge",
        .bag = &.{
            .{ .coin = 240 },
            .{ .key = "brass" },
            .{ .nothing = true },
        },
    };

    try Io.Dir.cwd().createDirPath(io, "zig-out");
    try data.writeFile(gpa, io, save_path, Save, save, .{});

    const bytes = try data.encodeAlloc(gpa, Save, save, .{});
    try out.print("--- saved {d} bytes to {s} ---\n", .{ bytes.len, save_path });
    try out.print("{d} of header, {d} of payload, {d} of checksum\n", .{
        data.header_size,
        bytes.len - data.header_size - 4,
        4,
    });
    // For comparison: the same thing as a Zig source literal.
    var as_text: Io.Writer.Allocating = .init(gpa);
    try std.zon.stringify.serialize(save, .{}, &as_text.writer);
    try out.print("the same value as .zon is {d} bytes\n\n", .{as_text.written().len});

    // --- load -----------------------------------------------------------

    var loaded = try data.readFile(gpa, io, save_path, Save, .limited64(1 << 20));
    defer loaded.deinit(gpa);

    try out.print("--- loaded ---\n", .{});
    try out.print("{s}, level {d}, at ({d}, {d}), {d} lives\n", .{
        loaded.value.name,
        loaded.value.level,
        loaded.value.at.x,
        loaded.value.at.y,
        loaded.value.lives,
    });
    const checkpoint = loaded.value.checkpoint;
    try out.print("last checkpoint: {s}\n", .{if (checkpoint.len == 0) "none" else checkpoint});
    try out.print("carrying:", .{});
    for (loaded.value.bag) |item| switch (item) {
        .coin => |n| try out.print(" {d} coins", .{n}),
        .key => |which| try out.print(" a {s} key", .{which}),
        .nothing => {},
    };
    try out.print("\n\n", .{});

    // --- a file from an older build -------------------------------------

    const old = try data.encodeAlloc(gpa, SaveV1, .{
        .name = "Grace",
        .level = 2,
        .at = .{ .x = 0, .y = 0 },
    }, .{});

    try out.print("--- a save from an older build ---\n", .{});
    // Reading it as the current type is refused rather than misread.
    if (data.decode(gpa, Save, old)) |_| {
        try out.print("as the current type: read, which it should not have been\n", .{});
    } else |err| {
        try out.print("as the current type: {s}\n", .{@errorName(err)});
    }

    // And this is the whole of migration: ask which schema, then convert.
    const upgraded = try load(gpa, old);
    try out.print("migrated: {s}, level {d}, {d} lives\n\n", .{
        upgraded.name,
        upgraded.level,
        upgraded.lives,
    });

    // --- a file that was damaged ----------------------------------------

    const bent = try gpa.dupe(u8, bytes);
    bent[data.header_size + 2] ^= 0x40;
    try out.print("--- one bit flipped in the payload ---\n", .{});
    if (data.decode(gpa, Save, bent)) |_| {
        try out.print("read anyway, which the checksum exists to prevent\n\n", .{});
    } else |err| {
        try out.print("{s}\n\n", .{@errorName(err)});
    }

    // --- a record with no allocator -------------------------------------

    const settings = try data.encodeAlloc(gpa, Settings, .{
        .volume = 0.8,
        .fullscreen = true,
        .difficulty = .hard,
    }, .{ .checksum = false });

    // No allocator in this call, and none needed: `Settings` has no slice in
    // it, and asking for one that does is a compile error.
    const read = try data.decodeFixed(Settings, settings);
    try out.print("--- {d} bytes, read with no allocator ---\n", .{settings.len});
    try out.print("volume {d}, fullscreen {}, {s}\n", .{
        read.volume,
        read.fullscreen,
        @tagName(read.difficulty),
    });

    try out.flush();
}

/// Read a save of whichever version is on the disk, and give back the current
/// one. A file says which schema it holds, so this is a `switch` and not a
/// mechanism.
fn load(gpa: std.mem.Allocator, bytes: []const u8) !Save {
    const held = try data.schemaOf(bytes);

    if (held == data.fingerprintOf(Save)) {
        const now = try data.decode(gpa, Save, bytes);
        return now.value;
    }
    if (held == data.fingerprintOf(SaveV1)) {
        const then = try data.decode(gpa, SaveV1, bytes);
        return .{
            .name = then.value.name,
            .level = then.value.level,
            .at = then.value.at,
            // The fields the old file has not got, given the values a new
            // game would have.
            .lives = 3,
            .checkpoint = "",
            .bag = &.{},
        };
    }
    return error.UnknownSaveVersion;
}

test "a save from either build loads as the current one" {
    const gpa = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const old = try data.encodeAlloc(gpa, SaveV1, .{
        .name = "Grace",
        .level = 2,
        .at = .{ .x = 1, .y = 2 },
    }, .{});
    defer gpa.free(old);

    const upgraded = try load(arena.allocator(), old);
    try std.testing.expectEqualStrings("Grace", upgraded.name);
    try std.testing.expectEqual(@as(u8, 3), upgraded.lives);
    try std.testing.expectEqual(@as(usize, 0), upgraded.bag.len);

    const current = try data.encodeAlloc(gpa, Save, upgraded, .{});
    defer gpa.free(current);

    const again = try load(arena.allocator(), current);
    try std.testing.expectEqual(@as(u16, 2), again.level);
    try std.testing.expectEqual(@as(f32, 2), again.at.y);
}
