// SPDX-License-Identifier: BSL-1.0

//! Fluxion Data - a type, written down and read back.
//!
//! A compact binary format for whatever a Zig type already describes, with
//! the description's fingerprint in the file - so a file written by an older
//! build is *noticed* rather than read as something it is not.
//!
//!   `schema`  what a type is, at compile time: its description and its number
//!   `write`   a value into bytes
//!   `read`    bytes back into a value
//!
//! ```zig
//! const data = @import("fluxion_data");
//!
//! const Player = struct { name: []const u8, level: u16, at: struct { x: f32, y: f32 } };
//!
//! const bytes = try data.encodeAlloc(gpa, Player, player, .{});
//! defer gpa.free(bytes);
//!
//! var read = try data.decode(gpa, Player, bytes);
//! defer read.deinit(gpa);
//! read.value.level == player.level;
//! ```
//!
//! **There is no text half, and that is deliberate.** Zig ships `std.zon` and
//! `std.json`, both good, and `.zon` is already the language every manifest in
//! this family is written in. What neither gives is a compact binary form with
//! a version on it, so that is what this is. Human-editable data belongs in
//! `.zon`; this is the format for shipping.
//!
//! **The schema is the type.** There is nothing to declare, nothing to
//! generate and no second description to keep in step: `schema.describe`
//! walks the Zig type at compile time and `schema.fingerprint` is that
//! description hashed. Change the type in a way that changes the bytes -
//! reorder two fields, widen an integer, rename a member - and the number
//! changes with it.
//!
//! **Which makes migration a `switch`, not a mechanism.** A file says which
//! schema it holds, and `schemaOf` reads that without decoding anything:
//!
//! ```zig
//! const version = try data.schemaOf(bytes);
//! if (version == data.fingerprintOf(PlayerV2)) {
//!     ...
//! } else if (version == data.fingerprintOf(PlayerV1)) {
//!     // read the old one, and convert
//! }
//! ```
//!
//! Nothing here allocates except through the allocator it is handed, and a
//! type with no slice in it needs no allocator at all - see `decodeFixed`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hashing = @import("fluxion_hash");

pub const schema = @import("schema.zig");
pub const write = @import("write.zig");
pub const read = @import("read.zig");

/// What a type is, as a string. See `schema`.
pub const describe = schema.describe;

/// The number that description is known by. See `schema`.
pub const fingerprintOf = schema.fingerprint;

/// Give back what `decode` allocated, for a caller not using an arena.
/// See `read`.
pub const free = read.free;

/// The four bytes every file starts with.
pub const magic = [4]u8{ 'F', 'X', 'D', 'T' };

/// The container's own version, which is not the schema's. It changes when
/// the framing changes, which it has not yet.
pub const format_version: u8 = 1;

/// Four of magic, one of version, one of flags, eight of fingerprint.
pub const header_size = 14;

pub const Options = struct {
    /// Put a CRC-32 of the payload after it.
    ///
    /// On, because it costs one pass over bytes already in cache and turns a
    /// damaged file into a message rather than into a value that looks
    /// plausible. Off for a file that is already inside something checksummed.
    checksum: bool = true,
};

pub const Error = error{
    /// The first four bytes are not this format's.
    NotFluxionData,
    /// A container version this build does not know how to frame.
    UnsupportedVersion,
    /// The file holds a different type than the one being asked for.
    /// `schemaOf` says which.
    SchemaMismatch,
    /// The payload does not match the CRC written after it.
    BadChecksum,
} || read.Error;

/// A value and whatever reading it allocated.
pub fn Decoded(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();

        /// Not needed by a caller who decoded into an arena.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            free(gpa, T, self.value);
            self.* = undefined;
        }
    };
}

// -------------------------------------------------------------------------
// Writing
// -------------------------------------------------------------------------

/// Write a header and a value into `w`.
///
/// The checksum is over the payload alone, so the header can be read without
/// having the rest.
pub fn encode(
    gpa: Allocator,
    w: *Io.Writer,
    comptime T: type,
    value: T,
    options: Options,
) (Allocator.Error || Io.Writer.Error)!void {
    // The payload is written first because the checksum goes after it and
    // the header before it, and one pass cannot do both.
    var payload: Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    write.value(&payload.writer, T, value) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    const bytes = payload.written();

    try w.writeAll(&magic);
    try w.writeByte(format_version);
    try w.writeByte(if (options.checksum) 1 else 0);
    try w.writeInt(u64, comptime fingerprintOf(T), .little);
    try w.writeAll(bytes);
    if (options.checksum) {
        var crc: hashing.Crc32 = .init();
        crc.update(bytes);
        try w.writeInt(u32, crc.final(), .little);
    }
}

/// Write into fresh memory. The caller frees it.
pub fn encodeAlloc(
    gpa: Allocator,
    comptime T: type,
    value: T,
    options: Options,
) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    encode(gpa, &out.writer, T, value, options) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

/// Write straight into a file at `path`, made or truncated.
pub fn writeFile(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    comptime T: type,
    value: T,
    options: Options,
) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var out = file.writer(io, &buffer);
    try encode(gpa, &out.interface, T, value, options);
    try out.interface.flush();
}

// -------------------------------------------------------------------------
// Reading
// -------------------------------------------------------------------------

/// Which schema a file holds, without decoding a byte of it.
///
/// This is the whole of migration: compare it against `fingerprintOf` for
/// each type this program knows, and read with the one that matches.
pub fn schemaOf(bytes: []const u8) Error!u64 {
    const head = try readHeader(bytes);
    return head.fingerprint;
}

/// Read a value out of a whole file's bytes.
pub fn decode(gpa: Allocator, comptime T: type, bytes: []const u8) Error!Decoded(T) {
    const head = try readHeader(bytes);
    if (head.fingerprint != comptime fingerprintOf(T)) return error.SchemaMismatch;

    var payload = bytes[header_size..];
    if (head.checksum) {
        if (payload.len < 4) return error.Truncated;
        const stated = std.mem.readInt(u32, payload[payload.len - 4 ..][0..4], .little);
        payload = payload[0 .. payload.len - 4];
        var crc: hashing.Crc32 = .init();
        crc.update(payload);
        if (crc.final() != stated) return error.BadChecksum;
    }

    var cursor: read.Cursor = .{ .bytes = payload };
    return .{ .value = try read.value(T, &cursor, gpa) };
}

/// Read a type that has no slice in it, and so needs no allocator.
///
/// A compile error for a type that does: the alternative would be an
/// allocator parameter that is sometimes ignored, and a caller who could not
/// tell which.
pub fn decodeFixed(comptime T: type, bytes: []const u8) Error!T {
    comptime {
        if (schema.allocates(T)) {
            @compileError("fluxion-data: " ++ @typeName(T) ++
                " has a slice in it, so reading it needs an allocator: use `decode`");
        }
    }
    // Nothing in it allocates, so the allocator is never reached.
    const decoded = try decode(failing, T, bytes);
    return decoded.value;
}

/// Read a value from a file.
pub fn readFile(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    comptime T: type,
    limit: Io.Limit,
) !Decoded(T) {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, limit);
    defer gpa.free(bytes);
    return decode(gpa, T, bytes);
}

const Header = struct {
    fingerprint: u64,
    checksum: bool,
};

fn readHeader(bytes: []const u8) Error!Header {
    if (bytes.len < header_size) return error.NotFluxionData;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.NotFluxionData;
    if (bytes[4] != format_version) return error.UnsupportedVersion;
    return .{
        .fingerprint = std.mem.readInt(u64, bytes[6..14], .little),
        .checksum = bytes[5] & 1 != 0,
    };
}

/// An allocator that refuses, for `decodeFixed`: nothing in a type without a
/// slice ever asks it for anything, and if something did the answer should be
/// a failure rather than a quiet allocation.
const failing: Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = struct {
            fn alloc(_: *anyopaque, _: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
                return null;
            }
        }.alloc,
        .resize = struct {
            fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
                return false;
            }
        }.resize,
        .remap = struct {
            fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
                return null;
            }
        }.remap,
        .free = struct {
            fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
        }.free,
    },
};

test {
    _ = schema;
    _ = write;
    _ = read;
    _ = @import("round_trip_test.zig");
}
