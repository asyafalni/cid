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
pub const cli_push = @import("cli/push.zig");
pub const cli_pull = @import("cli/pull.zig");
pub const cli_log = @import("cli/log.zig");
pub const cli_clone = @import("cli/clone.zig");
pub const cli_checkout = @import("cli/checkout.zig");
pub const cli_tag = @import("cli/tag.zig");
pub const cli_restore = @import("cli/restore.zig");
pub const cli_diff = @import("cli/diff.zig");
pub const pg = @import("store/pg.zig");
pub const s3 = @import("store/s3.zig");
pub const api = @import("server/api.zig");
pub const serve = @import("server/serve.zig");
pub const migrate = @import("core/migrate.zig");
pub const release = @import("core/release.zig");
pub const canonical = @import("manifest/canonical.zig");
pub const gitrepo = struct {
    pub const render = @import("gitrepo/render.zig");
    pub const writer = @import("gitrepo/writer.zig");
};
pub const uuid7 = @import("util/uuid7.zig");
pub const access = struct {
    pub const token = @import("access/token.zig");
    pub const auth = @import("access/auth.zig");
};
pub const cli_ssh = @import("cli/sshcmd.zig");
pub const client = struct {
    pub const index = @import("client/index.zig");
    pub const local = @import("client/local.zig");
    pub const cache = @import("client/cache.zig");
    pub const scan = @import("client/scan.zig");
    pub const workspace = @import("client/workspace.zig");
    pub const remote = @import("client/remote.zig");
    pub const sync = @import("client/sync.zig");
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
    _ = release;
    _ = canonical;
    _ = gitrepo.render;
    _ = access.token;
    _ = access.auth;
    _ = gitrepo.writer;
    _ = uuid7;
    _ = client.index;
    _ = client.local;
    _ = client.cache;
    _ = client.scan;
    _ = client.workspace;
    _ = client.remote;
    _ = client.sync;
    _ = cli_log;
    _ = cli_diff;
}
