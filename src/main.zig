const std = @import("std");
const kdl = @import("kdl");

const hlp = @import("helpers.zig");
const validation = @import("validation.zig");

const initial_validation = validation.initial_validation;

var file:?[]const u8 = null;

pub fn init() !void {
    const alloc = std.heap.page_allocator;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const valid = enum {
        @"--file", @"-f"
    };
    var next_used = false;
    for (args[1..], 2..) |arg, i| {
        if (next_used) continue;

        const a = std.meta.stringToEnum(valid, arg) orelse {
            try hlp.print.err("invalid arg: {s}\n", .{arg});
            std.process.exit(1);
        };

        switch (a) {
            .@"--file", .@"-f" => {
                if (args.len > i) {
                    file = try alloc.dupe(u8, args[i]);
                    next_used = true;
                }
            }
        }
    }
}

// TODO: replace main() with something otherthan testing 
pub fn main() !void {
    const alloc = std.heap.page_allocator;
    try init();
    if (file == null) {
        try hlp.print.err("no file provided\n", .{});
        std.process.exit(1);
    }
    const source = b: {
        var fi = std.fs.cwd().openFile(file.?, .{}) catch |e| {
            try hlp.print.err("failed to open file: {t}\n", .{e});
            std.process.exit(1);
        };
        defer fi.close();
        var re = fi.reader(&.{});
        break :b try re.interface.allocRemaining(alloc, .unlimited);
    };

    try hlp.validate_and_print(source);
}
