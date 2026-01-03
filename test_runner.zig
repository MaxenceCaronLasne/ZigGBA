const std = @import("std");
const builtin = @import("builtin");
const gba = @import("gba");

// GBA ROM header (required for ROM to boot)
export var header linksection(".gbaheader") =
    gba.initHeader("ZIGTEST", "AZGE", "00", 0);

pub export fn main() void {
    // Initialize debug output
    gba.debug.init();

    // Print header
    gba.debug.print("ZigGBA Test Runner\n", .{}) catch {};
    gba.debug.print("Running {d} tests...\n", .{builtin.test_functions.len}) catch {};

    var pass_count: usize = 0;
    var fail_count: usize = 0;

    // Run each test
    for (builtin.test_functions) |test_fn| {
        gba.debug.print("[TEST] {s}...", .{test_fn.name}) catch {};

        // Execute test and catch errors
        test_fn.func() catch |err| {
            gba.debug.print(" FAIL: {s}\n", .{@errorName(err)}) catch {};
            fail_count += 1;
            continue;
        };

        gba.debug.print(" PASS\n", .{}) catch {};
        pass_count += 1;
    }

    // Print summary
    gba.debug.print("\n--- RESULTS ---\n", .{}) catch {};
    gba.debug.print("Passed: {d}\n", .{pass_count}) catch {};
    gba.debug.print("Failed: {d}\n", .{fail_count}) catch {};

    if (fail_count == 0) {
        gba.debug.print("All tests passed!\n", .{}) catch {};
    }

    // Hang forever (standard GBA pattern)
    while (true) {}
}

// Custom panic handler for test assertion failures
pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    _ = error_return_trace;
    _ = ret_addr;
    gba.debug.print("PANIC: {s}\n", .{msg}) catch {};
    while (true) {}
}
