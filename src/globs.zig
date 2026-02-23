const std = @import("std");
const kdl = @import("kdl");

pub const validation_result = union(enum(i8)) {
    ok: struct {
        lines: []const []const u8 = &.{},
        line_count: usize = 0,
        no_ansi: struct {
            lines:[]const []const u8 = &.{},
            strung:[]const u8 = "",
        } = .{},
        strung: []const u8 = "",
    },
    err: struct {
        value: ?anyerror = null,
        data: kdl.StreamIterator, 
    },
};

const colors = struct {
    pub const symbol:str = "\x1b[1;38;2;115;115;115m";
    pub const typename:str = "\x1b[3;1;36m";
    pub const class:str = "\x1b[0;34m";
    pub const num:str = "\x1b[38;2;255;165;0m";
    pub const string:str = "\x1b[32m";
    pub const @"bool":str = "\x1b[33m";
    pub const other = "\x1b[36m";
    const str = []const u8;
};
