//! The cid library root. main.zig and the integration tests import this.

pub const command = @import("cli/command.zig");
pub const help = @import("cli/help.zig");
pub const version = @import("cli/version.zig");
pub const admin = @import("cli/admin.zig");
pub const pg = @import("store/pg.zig");
pub const migrate = @import("core/migrate.zig");

/// CLI exit codes (CLAUDE.md, "Rules for every command").
pub const ExitCode = enum(u8) {
    ok = 0,
    usage = 1,
    conflict = 2,
    integrity = 3,
    network = 4,
    access = 5,
};

test {
    _ = command;
    _ = help;
    _ = version;
    _ = admin;
    _ = pg;
    _ = migrate;
}
