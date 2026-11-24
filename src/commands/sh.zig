//! Interpret a POSIX shell subset from a script, `-c`, or standard input.
const std = @import("std");
const shell = @import("../shell/runtime.zig");
const process = @import("../shell/process.zig");
const Allocator = std.mem.Allocator;

pub fn run(_: Allocator, _: []const [:0]const u8) u8 {
    shell.diagnose("sh", null, "requires startup context");
    return 2;
}

const Invocation = struct {
    source: union(enum) { stdin, file: [:0]const u8, text: [:0]const u8 } = .stdin,
    zero: [:0]const u8,
    args: []const [:0]const u8,
    interactive: bool = false,
    no_glob: bool = false,

    fn parse(name: [:0]const u8, args: []const [:0]const u8) !Invocation {
        var result: Invocation = .{ .zero = name, .args = args };
        var command = false;
        var stdin = false;
        while (result.args.len != 0) {
            const arg = result.args[0];
            if (std.mem.eql(u8, arg, "--") or std.mem.eql(u8, arg, "-")) {
                result.args = result.args[1..];
                break;
            }
            if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) break;
            for (arg[1..]) |option| {
                if (arg[0] == '+' and option != 'f') return error.UnsupportedOption;
                switch (option) {
                    'c' => command = true,
                    's' => stdin = true,
                    'i' => result.interactive = true,
                    'f' => result.no_glob = arg[0] == '-',
                    else => return error.UnsupportedOption,
                }
            }
            result.args = result.args[1..];
        }
        if (command) {
            if (result.args.len == 0) return error.MissingCommand;
            result.source = .{ .text = result.args[0] };
            result.args = result.args[1..];
            if (result.args.len != 0) {
                result.zero = result.args[0];
                result.args = result.args[1..];
            }
        } else if (!stdin and result.args.len != 0) {
            result.zero = result.args[0];
            result.source = .{ .file = result.zero };
            result.args = result.args[1..];
        }
        return result;
    }
};

pub fn launch(allocator: Allocator, name: [:0]const u8, args: []const [:0]const u8, envp: process.Vector) u8 {
    return launchShell(allocator, name, args, envp) catch |err| {
        const message = switch (err) {
            error.UnsupportedOption => "unsupported option",
            error.MissingCommand => "-c requires a command string",
            else => shell.reason(err),
        };
        shell.diagnose("sh", null, message);
        return 2;
    };
}

fn launchShell(allocator: Allocator, name: [:0]const u8, args: []const [:0]const u8, envp: process.Vector) !u8 {
    const invocation = try Invocation.parse(name, args);
    const interactive = invocation.interactive or (invocation.source == .stdin and process.terminal(0) and process.terminal(2));
    const signals = try process.Signals.init(interactive);
    defer signals.deinit();
    process.normalizeInput(0);
    const positionals = try shell.operands(allocator, invocation.args);
    defer allocator.free(positionals);
    var runtime = try shell.Runtime.init(allocator, invocation.zero, positionals, envp, &signals);
    defer runtime.deinit();
    runtime.interactive = interactive;
    runtime.no_glob = invocation.no_glob;
    const result = switch (invocation.source) {
        .stdin => try runtime.runStdin(),
        .text => |text| try runtime.runText(text),
        .file => |file| runtime.runFile(file) catch |err| {
            shell.diagnose("sh", file, shell.reason(err));
            return 2;
        },
    };
    return result.status;
}

test "sh: invocation stops parsing options at the first operand" {
    const c = try Invocation.parse("sh", &.{ "-if", "+f", "-c", ":", "name", "-bad" });
    try std.testing.expect(c.interactive and !c.no_glob);
    try std.testing.expectEqualStrings(":", c.source.text);
    try std.testing.expectEqualStrings("name", c.zero);
    try std.testing.expectEqualStrings("-bad", c.args[0]);
    const file = try Invocation.parse("sh", &.{ "-", "script", "--" });
    try std.testing.expectEqualStrings("script", file.source.file);
    try std.testing.expectEqualStrings("--", file.args[0]);
    const stdin = try Invocation.parse("/bin/sh", &.{ "-s", "--", "argument" });
    try std.testing.expect(stdin.source == .stdin);
    try std.testing.expectEqualStrings("/bin/sh", stdin.zero);
    try std.testing.expectEqualStrings("argument", stdin.args[0]);
    try std.testing.expectError(error.UnsupportedOption, Invocation.parse("sh", &.{"-e"}));
    try std.testing.expectError(error.MissingCommand, Invocation.parse("sh", &.{"-c"}));
}
