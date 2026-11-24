//! Submit, list, and remove jobs for the same-user scheduler.
const std = @import("std");
const env = @import("../common/env.zig");
const args_parser = @import("../common/args.zig");
const at_time = @import("../common/at_time.zig");
const clock = @import("../common/at_clock.zig");
const storage = @import("../common/at_spool.zig");
const proc = @import("../shell/process.zig");
const diagnose = @import("../shell/runtime.zig").diagnose;
const Allocator = std.mem.Allocator;

const Submission = struct {
    file: ?[:0]const u8 = null,
    queue: u8 = 'a',
    mail: bool = false,
    numeric: ?[]const u8 = null,
    timespec: []const [:0]const u8 = &.{},
};

const Request = union(enum) {
    submit: Submission,
    list: struct { queue: ?u8, ids: []const [:0]const u8 },
    remove: []const [:0]const u8,
};

fn parse(args: []const [:0]const u8) !Request {
    var parser = args_parser.ArgParser.init(args);
    var list = false;
    var remove = false;
    var queue: ?u8 = null;
    var sub: Submission = .{};
    while (parser.next("mlrf:q:t:")) |option| switch (option) {
        'm' => sub.mail = true,
        'l' => list = true,
        'r' => remove = true,
        'f' => {
            if (sub.file != null or parser.optarg.?.len == 0) return error.InvalidArguments;
            sub.file = parser.optarg.?;
        },
        'q' => {
            const q = parser.optarg.?;
            if (queue != null or q.len != 1 or (q[0] != 'a' and q[0] != 'b')) return error.InvalidQueue;
            queue = q[0];
        },
        't' => {
            if (sub.numeric != null) return error.InvalidArguments;
            sub.numeric = parser.optarg.?;
        },
        else => return error.InvalidArguments,
    };
    const operands = parser.remaining();
    if (list or remove) {
        if ((list and remove) or sub.mail or sub.file != null or sub.numeric != null) return error.InvalidArguments;
        if (list) {
            if (queue != null and operands.len != 0) return error.InvalidArguments;
            return .{ .list = .{ .queue = queue, .ids = operands } };
        }
        if (queue != null or operands.len == 0) return error.InvalidArguments;
        return .{ .remove = operands };
    }
    if ((sub.numeric == null) == (operands.len == 0)) return error.InvalidArguments;
    sub.queue = queue orelse 'a';
    sub.timespec = operands;
    if (sub.queue == 'b' and (sub.numeric != null or !sub.mail or operands.len != 1 or
        !std.ascii.eqlIgnoreCase(std.mem.trim(u8, operands[0], " \t\r\n"), "now"))) return error.InvalidBatchSubmission;
    return .{ .submit = sub };
}

pub fn run(_: Allocator, _: []const [:0]const u8) u8 {
    diagnose("at", null, "requires startup context");
    return 1;
}

pub fn launch(allocator: Allocator, args: []const [:0]const u8, envp: env.Vector) u8 {
    const request = parse(args) catch |err| return fail("at", null, err);
    const tz = env.get(envp, "TZ");
    return switch (request) {
        .submit => |sub| submit("at", allocator, sub, envp, tz),
        .list => |opts| listJobs(allocator, opts.queue, opts.ids, tz) catch |err| fail("at", null, err),
        .remove => |ids| removeJobs(allocator, ids) catch |err| fail("at", null, err),
    };
}

pub fn submitBatch(allocator: Allocator, envp: env.Vector) u8 {
    return submit("batch", allocator, .{ .queue = 'b', .mail = true, .timespec = &.{"now"} }, envp, env.get(envp, "TZ"));
}

fn submit(command: []const u8, allocator: Allocator, sub: Submission, envp: env.Vector, tz: ?[]const u8) u8 {
    const now = clock.now() catch |err| return fail(command, null, err);
    const due = if (sub.queue == 'b') now else if (sub.numeric) |numeric|
        at_time.parseNumeric(allocator, now, tz, numeric) catch |err| return fail(command, numeric, err)
    else
        at_time.parse(allocator, now, tz, sub.timespec) catch |err| return fail(command, null, err);
    var date_buf: [64]u8 = undefined;
    const date = at_time.format(allocator, due, tz, &date_buf) catch |err| return fail(command, null, err);

    if (sub.file == null) _ = proc.flags(0) catch |err| return fail(command, null, err);
    var spool = storage.Spool.openForSubmission(allocator) catch |err| return fail(command, null, err);
    defer spool.close();
    const source = if (sub.file) |path| proc.open(path, .{}) catch |err| return fail(command, path, err) else 0;
    defer if (sub.file != null) proc.close(source);
    const id = spool.submit(due, sub.queue, sub.mail, source, envp) catch |err| return fail(command, sub.file, err);
    var line: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "job {s} at {s}\n", .{ &id, date }) catch unreachable;
    proc.write(2, text) catch {};
    return 0;
}

fn listJobs(allocator: Allocator, queue: ?u8, ids: []const [:0]const u8, tz: ?[]const u8) !u8 {
    var spool = try storage.Spool.open(allocator);
    defer spool.close();
    const jobs = try spool.list(allocator);
    defer allocator.free(jobs);
    if (ids.len == 0) {
        for (jobs) |job| if (queue == null or job.queue == queue.?) try printJob(allocator, job, tz);
        return 0;
    }
    var result: u8 = 0;
    for (ids) |id| {
        for (jobs) |job| {
            if (!std.mem.eql(u8, id, &job.id)) continue;
            try printJob(allocator, job, tz);
            break;
        } else result = fail("at", id, if (storage.validateId(id)) error.JobNotFound else error.InvalidJobId);
    }
    return result;
}

fn printJob(allocator: Allocator, job: storage.Job, tz: ?[]const u8) !void {
    var date_buf: [64]u8 = undefined;
    const date = try at_time.format(allocator, job.due, tz, &date_buf);
    var line: [128]u8 = undefined;
    try proc.write(1, try std.fmt.bufPrint(&line, "{s}\t{s}\n", .{ &job.id, date }));
}

fn removeJobs(allocator: Allocator, ids: []const [:0]const u8) !u8 {
    var spool = try storage.Spool.open(allocator);
    defer spool.close();
    var result: u8 = 0;
    for (ids) |id| {
        if (!storage.validateId(id)) {
            result = fail("at", id, error.InvalidJobId);
            continue;
        }
        spool.remove(id) catch |err| {
            result = fail("at", id, err);
        };
    }
    return result;
}

fn fail(command: []const u8, subject: ?[]const u8, err: anyerror) u8 {
    diagnose(command, subject, switch (err) {
        error.InvalidArguments => "invalid option or operand combination",
        error.InvalidBatchSubmission => "queue b requires -m now",
        error.InvalidQueue => "invalid queue (use a or b)",
        error.InvalidJobId => "invalid job ID",
        error.JobNotFound => "no such pending job",
        error.SubmissionDenied => "not permitted to submit jobs",
        error.ElevatedCredentials => "scheduler does not support setuid or setgid execution",
        else => @import("../shell/runtime.zig").reason(err),
    });
    return 1;
}

test "at: validate submission, list and remove forms" {
    const file = (try parse(&.{ "-mfscript", "-q", "a", "--", "noon", "tomorrow" })).submit;
    try std.testing.expectEqualStrings("script", file.file.?);
    try std.testing.expectEqualStrings("noon", file.timespec[0]);
    try std.testing.expect(file.mail);
    try std.testing.expectEqualStrings("208912311200", (try parse(&.{ "-t", "208912311200" })).submit.numeric.?);
    try std.testing.expectEqual('b', (try parse(&.{ "-q", "b", "-m", "NOW" })).submit.queue);
    try std.testing.expectEqual('b', (try parse(&.{ "-lq", "b" })).list.queue.?);
    try std.testing.expectEqualStrings("job", (try parse(&.{ "-r", "job" })).remove[0]);

    try std.testing.expectError(error.InvalidArguments, parse(&.{}));
    try std.testing.expectError(error.InvalidArguments, parse(&.{"-r"}));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "-lq", "a", "id" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "-l", "-m" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "-lr", "id" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "-t", "208912311200", "now" }));
    try std.testing.expectError(error.InvalidQueue, parse(&.{ "-q", "c", "now" }));
    try std.testing.expectError(error.InvalidBatchSubmission, parse(&.{ "-q", "b", "now" }));
    try std.testing.expectError(error.InvalidBatchSubmission, parse(&.{ "-q", "b", "-m", "now", "+1", "hour" }));
}
