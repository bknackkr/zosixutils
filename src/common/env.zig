//! Access the inherited environment before initializing threaded I/O.
const std = @import("std");

pub const Vector = [*:null]const ?[*:0]const u8;

pub fn get(env: Vector, comptime name: []const u8) ?[:0]const u8 {
    var i: usize = 0;
    while (env[i]) |entry| : (i += 1) {
        const text = std.mem.span(entry);
        if (std.mem.startsWith(u8, text, name ++ "=")) return text[name.len + 1 ..];
    }
    return null;
}
