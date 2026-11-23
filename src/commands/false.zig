//! Exit with status 1. No flags; arguments are ignored.

const std = @import("std");
const common_error = @import("../common/error.zig");

pub fn run(allocator: std.mem.Allocator, args: []const [:0]const u8) u8 {
	_ = allocator;
	_ = args;
	return common_error.EXIT_FAILURE;
}

pub fn main() u8 {
	return common_error.EXIT_FAILURE;
}
