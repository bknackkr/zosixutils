//! Shell-only wait for asynchronous children.
const std = @import("std");
const process = @import("../shell/process.zig");

pub fn run(ctx: anytype, args: []const [:0]const u8) !u8 {
    var operands = args;
    if (operands.len != 0 and std.mem.eql(u8, operands[0], "--")) operands = operands[1..];
    if (operands.len == 0) return ctx.waitChild(null);
    var status: u8 = 0;
    for (operands) |operand| {
        var valid = operand.len != 0;
        for (operand) |c| if (!std.ascii.isDigit(c)) {
            valid = false;
            break;
        };
        const pid: ?process.Pid = if (valid) std.fmt.parseInt(process.Pid, operand, 10) catch null else null;
        if (pid == null) {
            process.write(2, "wait: ") catch {};
            process.write(2, operand) catch {};
            process.write(2, ": invalid PID\n") catch {};
            status = 1;
            continue;
        }
        status = try ctx.waitChild(pid.?);
    }
    return status;
}

test "wait: operands are visited in order and no operands drain the registry" {
    const Mock = struct {
        calls: [3]?process.Pid = undefined,
        len: usize = 0,

        fn waitChild(self: *@This(), pid: ?process.Pid) !u8 {
            self.calls[self.len] = pid;
            self.len += 1;
            return if (pid) |value| if (value == 42) 7 else 127 else 0;
        }
    };
    var mock: Mock = .{};
    try std.testing.expectEqual(7, try run(&mock, &.{ "--", "17", "42" }));
    try std.testing.expectEqual(0, try run(&mock, &.{}));
    try std.testing.expectEqualSlices(?process.Pid, &.{ 17, 42, null }, &mock.calls);
}
