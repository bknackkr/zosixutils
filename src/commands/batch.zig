//! Submit a batch job that always requests completion mail.
const std = @import("std");
const at = @import("at.zig");
const env = @import("../common/env.zig");
const diagnose = @import("../shell/runtime.zig").diagnose;

pub fn run(_: std.mem.Allocator, _: []const [:0]const u8) u8 {
    diagnose("batch", null, "requires startup context");
    return 1;
}

pub fn launch(allocator: std.mem.Allocator, args: []const [:0]const u8, envp: env.Vector) u8 {
    if (args.len != 0) {
        diagnose("batch", args[0], "does not accept options or operands");
        return 1;
    }
    return at.submitBatch(allocator, envp);
}

test "batch: rejects options and operands before using the queue" {
    try std.testing.expectEqual(1, launch(std.testing.allocator, &.{"now"}, &.{null}));
    try std.testing.expectEqual(1, launch(std.testing.allocator, &.{"-m"}, &.{null}));
}
