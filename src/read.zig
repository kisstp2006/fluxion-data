// SPDX-License-Identifier: BSL-1.0

//! A value, read back.
//!
//! The mirror of `write`, with one thing the writer does not have to do:
//! decide what to believe. Every length is checked against the bytes that are
//! left before a single one is allocated, every enum value against the members
//! the enum has, and every union tag against the arms it has. A file this
//! program did not write is a file that may say anything.

const std = @import("std");
const Allocator = std.mem.Allocator;

const varint = @import("fluxion_encoding").varint;
const schema = @import("schema.zig");

pub const Error = error{
    /// The bytes ran out in the middle of a value.
    Truncated,
    /// A varint carrying more bits than its type holds.
    Overflow,
    /// A byte that is neither zero nor one where a `bool` was written.
    BadBool,
    /// A number no member of that enum has.
    BadEnum,
    /// An arm number the union has not got.
    BadUnion,
    /// A slice claiming more elements than the rest of the file could hold.
    TooManyElements,
} || Allocator.Error;

/// Where the reading has got to.
pub const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn remaining(self: Cursor) usize {
        return self.bytes.len - self.at;
    }

    pub fn take(self: *Cursor, n: usize) Error![]const u8 {
        if (self.remaining() < n) return error.Truncated;
        defer self.at += n;
        return self.bytes[self.at..][0..n];
    }

    pub fn byte(self: *Cursor) Error!u8 {
        return (try self.take(1))[0];
    }

    pub fn number(self: *Cursor, comptime T: type) Error!T {
        const decoded = varint.decode(T, self.bytes[self.at..]) catch |err| switch (err) {
            error.UnexpectedEnd => return error.Truncated,
            error.Overflow => return error.Overflow,
        };
        self.at += decoded.len;
        return decoded.value;
    }
};

/// Read one value. `gpa` is only ever asked for memory when the type has a
/// slice in it somewhere - see `schema.allocates`.
pub fn value(comptime T: type, cursor: *Cursor, gpa: Allocator) Error!T {
    comptime schema.check(T);

    switch (@typeInfo(T)) {
        .bool => return switch (try cursor.byte()) {
            0 => false,
            1 => true,
            // Anything else is a file that was not written by this, and
            // guessing which way it meant would be worse than saying so.
            else => error.BadBool,
        },

        .int => |info| {
            if (info.bits <= 8) {
                const wide: std.meta.Int(info.signedness, 8) = @bitCast(try cursor.byte());
                return std.math.cast(T, wide) orelse error.Overflow;
            }
            return cursor.number(T);
        },

        .float => |info| {
            const Bits = std.meta.Int(.unsigned, info.bits);
            const bytes = try cursor.take(@sizeOf(Bits));
            return @bitCast(std.mem.readInt(Bits, bytes[0..@sizeOf(Bits)], .little));
        },

        .@"enum" => |info| {
            const tag = try value(info.tag_type, cursor, gpa);
            return std.enums.fromInt(T, tag) orelse error.BadEnum;
        },

        .optional => |info| return switch (try cursor.byte()) {
            0 => null,
            1 => try value(info.child, cursor, gpa),
            else => error.BadBool,
        },

        .array => |info| {
            var out: T = undefined;
            var built: usize = 0;
            errdefer for (out[0..built]) |item| free(gpa, info.child, item);
            while (built < info.len) : (built += 1) {
                out[built] = try value(info.child, cursor, gpa);
            }
            return out;
        },

        .pointer => |info| return slice(info.child, cursor, gpa),

        .@"struct" => |info| {
            if (info.layout == .@"packed") {
                return @bitCast(try value(info.backing_integer.?, cursor, gpa));
            }
            var out: T = undefined;
            // Which fields have been filled, so that failing part of the way
            // through frees what was allocated and no more.
            comptime var built: usize = 0;
            errdefer inline for (info.fields[0..built]) |field| {
                free(gpa, field.type, @field(out, field.name));
            };
            inline for (info.fields) |field| {
                @field(out, field.name) = try value(field.type, cursor, gpa);
                built += 1;
            }
            return out;
        },

        .@"union" => |info| {
            const index = try cursor.number(u64);
            if (index >= info.fields.len) return error.BadUnion;
            inline for (info.fields, 0..) |field, i| {
                if (index == i) {
                    return @unionInit(T, field.name, try value(field.type, cursor, gpa));
                }
            }
            unreachable;
        },

        else => unreachable,
    }
}

fn slice(comptime Child: type, cursor: *Cursor, gpa: Allocator) Error![]Child {
    const claimed = try cursor.number(u64);

    // A length is only believable if the bytes to fill it are still there.
    // Every element costs at least one byte except for a type with nothing
    // in it at all, and there is no such type here.
    const smallest = comptime @max(1, schema.minimumSize(Child));
    if (claimed > cursor.remaining() / smallest) return error.TooManyElements;
    const length: usize = @intCast(claimed);

    if (Child == u8) {
        const bytes = try cursor.take(length);
        return gpa.dupe(u8, bytes);
    }

    const out = try gpa.alloc(Child, length);
    errdefer gpa.free(out);

    var built: usize = 0;
    errdefer for (out[0..built]) |item| free(gpa, Child, item);
    while (built < length) : (built += 1) {
        out[built] = try value(Child, cursor, gpa);
    }
    return out;
}

/// Give back everything reading a `T` allocated.
///
/// A no-op for a type with no slice in it, which the compiler removes
/// entirely. A caller who decoded into an arena has nothing to call.
pub fn free(gpa: Allocator, comptime T: type, from: T) void {
    if (comptime !schema.allocates(T)) return;

    switch (@typeInfo(T)) {
        .pointer => |info| {
            for (from) |item| free(gpa, info.child, item);
            gpa.free(from);
        },
        .optional => |info| if (from) |present| free(gpa, info.child, present),
        .array => |info| for (from) |item| free(gpa, info.child, item),
        // A packed struct owns nothing: it is a number.
        .@"struct" => |info| if (info.layout != .@"packed") inline for (info.fields) |field| {
            free(gpa, field.type, @field(from, field.name));
        },
        .@"union" => switch (from) {
            inline else => |payload| free(gpa, @TypeOf(payload), payload),
        },
        else => {},
    }
}
