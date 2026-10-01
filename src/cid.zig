//! The cid library root. main.zig and the integration tests import this.

pub const command = @import("cli/command.zig");
pub const help = @import("cli/help.zig");
pub const version = @import("cli/version.zig");
pub const admin = @import("cli/admin.zig");
pub const common = @import("cli/common.zig");
pub const cli_init = @import("cli/init.zig");
pub const cli_add = @import("cli/add.zig");
pub const cli_commit = @import("cli/commit.zig");
pub const cli_status = @import("cli/status.zig");
pub const pg = @import("store/pg.zig");
pub const s3 = @import("store/s3.zig");
pub const api = @import("server/api.zig");
pub const serve = @import("server/serve.zig");
pub const migrate = @import("core/migrate.zig");
pub const uuid7 = @import("util/uuid7.zig");
pub const client = struct {
    pub const index = @import("client/index.zig");
    pub const local = @import("client/local.zig");
    pub const cache = @import("client/cache.zig");
    pub const scan = @import("client/scan.zig");
    pub const workspace = @import("client/workspace.zig");
};

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
    _ = s3;
    _ = api;
    _ = serve;
    _ = migrate;
    _ = uuid7;
    _ = client.index;
    _ = client.local;
    _ = client.cache;
    _ = client.scan;
    _ = client.workspace;
}
