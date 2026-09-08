// SPDX-License-Identifier: BSL-1.0

//! A value, written down.
//!
//! One walk over the type at compile time, one pass over the value at run
//! time, and nothing between them: there is no intermediate tree, no map of
//! field names, and no allocation. What comes out is the shortest thing that
//! can be read back.
//!
//! The rules are in the README, and this file is them.

const std = @import("std");
const Io = std.Io;

const varint = @import("fluxion_encoding").varint;
const schema = @import("schema.zig");

/// Write the value of a `T`, with no header. `root.encode` puts one in front.
pub fn value(w: *Io.Writer, comptime T: type, from: T) Io.Writer.Error!void {
    comptime schema.check(T);

    switch (@typeInfo(T)) {
        .bool => try w.writeByte(@intFromBool(from)),

        .int => |info| {
            // A byte is a byte. Anything wider is a varint, because the
            // numbers a program actually stores are small far more often
            // than they are not.
            if (info.bits <= 8) {
                try w.writeByte(@bitCast(@as(std.meta.Int(info.signedness, 8), from)));
            } else {
                var buffer: [varint.maxLen(T)]u8 = undefined;
                // The buffer is the widest the type can need, so there is no
                // running out of room.
                const n = varint.encode(T, &buffer, from) catch unreachable;
                try w.writeAll(buffer[0..n]);
            }
        },

        .float => |info| {
            const Bits = std.meta.Int(.unsigned, info.bits);
            try w.writeInt(Bits, @bitCast(from), .little);
        },

        .@"enum" => |info| try value(w, info.tag_type, @intFromEnum(from)),

        .optional => |info| {
            if (from) |present| {
                try w.writeByte(1);
                try value(w, info.child, present);
            } else {
                try w.writeByte(0);
            }
        },

        // No length: the schema already said how many.
        .array => |info| for (from) |item| try value(w, info.child, item),

        .pointer => |info| {
            try length(w, from.len);
            if (info.child == u8) {
                // The common one, and the one worth not looping over.
                try w.writeAll(from);
            } else {
                for (from) |item| try value(w, info.child, item);
            }
        },

        .@"struct" => |info| {
            // A packed struct is a number wearing a hat, and the number is
            // what gets written: Zig fixes the bit layout, so it is the same
            // number on every machine.
            if (info.layout == .@"packed") {
                return value(w, info.backing_integer.?, @bitCast(from));
            }
            inline for (info.fields) |field| {
                try value(w, field.type, @field(from, field.name));
            }
        },

        // The arm's position, not its tag value: what the file says is
        // "the third one", and the schema says which that is.
        .@"union" => |info| switch (from) {
            inline else => |payload, tag| {
                const index = comptime indexOf(info, @tagName(tag));
                try length(w, index);
                try value(w, @TypeOf(payload), payload);
            },
        },

        else => unreachable,
    }
}

/// A count: how long a slice is, or which arm a union is holding. Always a
/// varint, so a short string costs one byte to say so.
pub fn length(w: *Io.Writer, n: usize) Io.Writer.Error!void {
    var buffer: [varint.maxLen(u64)]u8 = undefined;
    const written = varint.encode(u64, &buffer, @intCast(n)) catch unreachable;
    try w.writeAll(buffer[0..written]);
}

fn indexOf(comptime info: std.builtin.Type.Union, comptime name: []const u8) usize {
    comptime {
        for (info.fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, name)) return i;
        }
        unreachable;
    }
}
