//! Read UTC seconds, using the time64 syscall on 32-bit Linux where available.
const linux = @import("std").os.linux;

pub fn now() !i64 {
    if (@hasField(linux.SYS, "clock_gettime64")) {
        var time: linux.kernel_timespec = undefined;
        switch (linux.errno(linux.syscall2(.clock_gettime64, @backingInt(linux.clockid_t.REALTIME), @intFromPtr(&time)))) {
            .SUCCESS => return time.sec,
            .NOSYS => {},
            else => return error.ClockUnavailable,
        }
    }
    var time: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.REALTIME, &time)) != .SUCCESS) return error.ClockUnavailable;
    return time.sec;
}
