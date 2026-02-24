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
                } else {
                    try hlp.print.err("provided file arg but no value provided\n", .{}); 
                    std.process.exit(1);
                }
            }
        }
    }
}

pub fn main() !void {
    try init();
    const alloc = std.heap.page_allocator;
    const source = if (file) |f| b:{
        var fi = std.fs.cwd().openFile(f, .{}) catch |e| {
            try hlp.print.err("failed to open file: {t}\n", .{e});
            std.process.exit(1);
        };
        defer fi.close();
        var re = fi.reader(&.{});
        break :b try re.interface.allocRemaining(alloc, .unlimited);
    } else b:{
        var wr = std.Io.Writer.Allocating.init(alloc);
        defer wr.deinit();
        var stdin = std.fs.File.stdin(); 
        var re = stdin.reader(&.{});
        _ = try re.interface.streamRemaining(&wr.writer);
        break :b try wr.toOwnedSlice();
    };

    try hlp.validate_and_print(source);
}
