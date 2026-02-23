const std = @import("std");
const kdl = @import("kdl");

const hlp = @import("helpers.zig");
const validation = @import("validation.zig");

const initial_validation = validation.initial_validation;

// TODO: replace main() with something otherthan testing 
pub fn main() !void {
    try hlp.validate_and_print(@embedFile("config.kdl"));
}
