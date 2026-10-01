//! Object storage via nilo_s3 (CLAUDE.md, Zig conventions): SigV4, the
//! pool, presigning and multipart all live upstream; this file is cid's
//! shape over one Bucket — the storage rules (path style, real payload
//! hash, multipart over 64 MB) and the method names the call sites grew
//! up with.
//!
//! **The bucket is named `cid`, at comptime.** nilo's ADR 059 makes a
//! bucket a type with its name compiled in, and cid ships one static
//! binary, so the name cannot come from the environment. Fixed names are
//! what git does with `.git`; deployments create a bucket called `cid`
//! (docker-compose.test.yml shows how) and CID_S3_BUCKET is gone.
//!
//! Every call takes a Scope — the request's Ctx in the server, a Run in
//! admin commands and tests — the same rule the database follows.

const std = @import("std");
pub const s3 = @import("nilo_s3");

/// One Bucket type for all of cid's objects. The 1 GiB ceiling is the
/// largest thing a bounded read will ever hold (a manifest under
/// `cid admin verify`); item fetches are size-checked against their own
/// recorded size before a byte moves, so the ceiling is protection, not
/// an allocation.
pub const Items = s3.Bucket("cid", .{ .style = .path, .max_bytes = 1 << 30 });

pub const Config = struct {
    /// e.g. "http://127.0.0.1:8333"
    endpoint: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    region: []const u8 = "us-east-1",
    /// Objects above this go up in parts (storage rules: multipart over
    /// 64 MB). Tests lower it; S3 parts must be at least 5 MB.
    multipart_threshold: u64 = 64 * 1024 * 1024,
};

pub const Error = Items.Error;

pub const Client = struct {
    store: s3.Store,
    items: Items,
    multipart_threshold: u64,

    /// Out-pointer init, because `items` keeps a pointer to `store`:
    /// a Client that moved after `open` would dangle.
    pub fn open(self: *Client, gpa: std.mem.Allocator, config: Config) !void {
        self.multipart_threshold = config.multipart_threshold;
        self.store = try s3.open(gpa, .{
            .endpoint = config.endpoint,
            .region = config.region,
            .credentials = .{ .static = .{
                .access_key_id = config.access_key,
                .secret_access_key = config.secret_key,
            } },
        });
        errdefer self.store.deinit();
        self.items = try Items.open(&self.store);
    }

    /// For a program that never calls `listen()`: admin commands, the
    /// background loop, tests. The server instead provides `store` and
    /// `items` to its App, and `listen()` starts them on its own loop.
    pub fn start(self: *Client, io: std.Io) !void {
        try self.store.nilo_start(io, .off);
        try self.items.nilo_start(io, .off);
    }

    pub fn deinit(self: *Client) void {
        self.items.deinit();
        self.store.deinit();
    }

    /// Whether the `cid` bucket exists, asked with one bounded list.
    /// Creation is the deployment's job (nilo_s3 has no CreateBucket,
    /// on purpose); this check is what lets `cid admin serve` fail with
    /// the fix named instead of every upload failing later.
    pub fn bucketReady(self: *Client, scope: anytype) bool {
        _ = self.items.list(scope, .{ .max_keys = 1 }) catch return false;
        return true;
    }

    pub fn putObject(self: *Client, scope: anytype, key: []const u8, bytes: []const u8) Error!void {
        if (bytes.len > self.multipart_threshold) {
            var reader = std.Io.Reader.fixed(bytes);
            return self.items.putMultipart(scope, key, .{
                .reader = &reader,
                .content_type = "application/octet-stream",
            });
        }
        return self.items.put(scope, key, .{
            .bytes = bytes,
            .content_type = "application/octet-stream",
        });
    }

    /// The whole object in the Scope. `error.NotFound` when it is not
    /// there; the comptime 1 GiB ceiling refuses anything larger before
    /// a byte of it is read.
    pub fn getObjectAlloc(self: *Client, scope: anytype, key: []const u8) Error![]const u8 {
        const object = try self.items.get(scope, key);
        return object.bytes.view();
    }

    /// The object's size, or null when storage does not have it — the
    /// shape the dedup check and the upload verifier both want.
    pub fn headObject(self: *Client, scope: anytype, key: []const u8) Error!?u64 {
        const meta = self.items.head(scope, key) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
        return meta.len;
    }

    pub fn deleteObject(self: *Client, scope: anytype, key: []const u8) Error!void {
        return self.items.delete(scope, key);
    }

    pub fn presignGet(self: *Client, scope: anytype, key: []const u8, seconds: u32) Error![]const u8 {
        const link = try self.items.presign(scope, key, seconds);
        return link.url.view();
    }

    pub fn presignPut(self: *Client, scope: anytype, key: []const u8, seconds: u32) Error![]const u8 {
        const link = try self.items.presignPut(scope, key, seconds);
        return link.url.view();
    }
};
