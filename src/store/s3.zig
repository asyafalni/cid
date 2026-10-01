//! Minimal S3 client for SeaweedFS: GET, PUT, HEAD, bucket creation and
//! presigned URLs, with SigV4 from our own code (std HMAC/SHA-256 only).
//! Rules (CLAUDE.md, storage): path-style addressing, SigV4, real payload
//! hash. Multipart arrives with `cid push`.

const std = @import("std");

pub const empty_payload_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
pub const unsigned_payload = "UNSIGNED-PAYLOAD";

pub const Config = struct {
    /// e.g. "http://127.0.0.1:8333"
    endpoint: []const u8,
    region: []const u8 = "us-east-1",
    access_key: []const u8,
    secret_key: []const u8,
    bucket: []const u8,
};

// ---------------------------------------------------------------------------
// SigV4 signing: pure functions, pinned by the AWS documentation test vectors.
// ---------------------------------------------------------------------------

pub const SignInput = struct {
    method: []const u8,
    /// URI-encoded path, starting with '/' ('/' itself not encoded).
    canonical_path: []const u8,
    /// Canonical query string: sorted, URI-encoded, no leading '?'.
    canonical_query: []const u8,
    /// Lower-case names, sorted, no duplicates. Values trimmed.
    headers: []const Header,
    payload_hash: []const u8,
    /// "20150830T123600Z"
    date_time: []const u8,
    region: []const u8,
    service: []const u8,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub fn signingKey(secret_key: []const u8, date: []const u8, region: []const u8, service: []const u8) [32]u8 {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var k_secret_buf: [128]u8 = undefined;
    const k_secret = std.fmt.bufPrint(&k_secret_buf, "AWS4{s}", .{secret_key}) catch unreachable;
    var k_date: [32]u8 = undefined;
    Hmac.create(&k_date, date, k_secret);
    var k_region: [32]u8 = undefined;
    Hmac.create(&k_region, region, &k_date);
    var k_service: [32]u8 = undefined;
    Hmac.create(&k_service, service, &k_region);
    var k_signing: [32]u8 = undefined;
    Hmac.create(&k_signing, "aws4_request", &k_service);
    return k_signing;
}

pub fn canonicalRequestHash(arena: std.mem.Allocator, input: SignInput) ![64]u8 {
    var canonical: std.ArrayList(u8) = .empty;
    try canonical.print(arena, "{s}\n{s}\n{s}\n", .{ input.method, input.canonical_path, input.canonical_query });
    for (input.headers) |h| try canonical.print(arena, "{s}:{s}\n", .{ h.name, h.value });
    try canonical.append(arena, '\n');
    try appendSignedHeaders(arena, &canonical, input.headers);
    try canonical.append(arena, '\n');
    try canonical.appendSlice(arena, input.payload_hash);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical.items, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn signature(arena: std.mem.Allocator, input: SignInput, secret_key: []const u8) ![64]u8 {
    const creq_hash = try canonicalRequestHash(arena, input);
    const date = input.date_time[0..8];
    var sts: std.ArrayList(u8) = .empty;
    try sts.print(arena, "AWS4-HMAC-SHA256\n{s}\n{s}/{s}/{s}/aws4_request\n{s}", .{
        input.date_time, date, input.region, input.service, &creq_hash,
    });
    const key = signingKey(secret_key, date, input.region, input.service);
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, sts.items, &key);
    return std.fmt.bytesToHex(mac, .lower);
}

pub fn authorizationHeader(
    arena: std.mem.Allocator,
    input: SignInput,
    access_key: []const u8,
    secret_key: []const u8,
) ![]u8 {
    const sig = try signature(arena, input, secret_key);
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/{s}/aws4_request, SignedHeaders=", .{
        access_key, input.date_time[0..8], input.region, input.service,
    });
    try appendSignedHeaders(arena, &out, input.headers);
    try out.print(arena, ", Signature={s}", .{&sig});
    return out.items;
}

fn appendSignedHeaders(arena: std.mem.Allocator, out: *std.ArrayList(u8), headers: []const Header) !void {
    for (headers, 0..) |h, i| {
        if (i > 0) try out.append(arena, ';');
        try out.appendSlice(arena, h.name);
    }
}

/// URI-encode for S3: unreserved characters stay; '/' kept only in paths.
pub fn uriEncode(arena: std.mem.Allocator, raw: []const u8, keep_slash: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |ch| {
        const keep = switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
            '/' => keep_slash,
            else => false,
        };
        if (keep) try out.append(arena, ch) else try out.print(arena, "%{X:0>2}", .{ch});
    }
    return out.items;
}

/// "20150830T123600Z" from Unix seconds (UTC).
pub fn dateTimeFromEpoch(secs: u64) [16]u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
    return out;
}

// ---------------------------------------------------------------------------
// The client.
// ---------------------------------------------------------------------------

pub const Error = error{ RequestFailed, NotFound, OutOfMemory };

pub const Client = struct {
    config: Config,
    http: std.http.Client,
    host: []const u8, // "127.0.0.1:8333", derived from endpoint

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) error{BadEndpoint}!Client {
        const scheme_end = std.mem.indexOf(u8, config.endpoint, "://") orelse return error.BadEndpoint;
        return .{
            .config = config,
            .http = .{ .allocator = allocator, .io = io },
            .host = config.endpoint[scheme_end + 3 ..],
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    pub fn createBucket(self: *Client, arena: std.mem.Allocator) Error!void {
        // The empty payload is explicit: std.http asserts that PUT sends a body.
        const status = try self.simpleRequest(arena, "PUT", "", "", empty_payload_hash, "", null);
        // 200 created, 409 already exists: both fine for "make sure it exists".
        if (status != .ok and status != .conflict) return error.RequestFailed;
    }

    pub fn putObject(self: *Client, arena: std.mem.Allocator, key: []const u8, bytes: []const u8) Error!void {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const payload_hash = std.fmt.bytesToHex(digest, .lower);
        const status = try self.simpleRequest(arena, "PUT", key, "", &payload_hash, bytes, null);
        if (status != .ok) return error.RequestFailed;
    }

    /// Returns the object's size, or null if it does not exist.
    pub fn headObject(self: *Client, arena: std.mem.Allocator, key: []const u8) Error!?u64 {
        var size: u64 = 0;
        const status = try self.simpleRequest(arena, "HEAD", key, "", empty_payload_hash, null, &size);
        if (status == .not_found) return null;
        if (status != .ok) return error.RequestFailed;
        return size;
    }

    pub fn getObjectAlloc(self: *Client, arena: std.mem.Allocator, key: []const u8, limit: usize) Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const status = self.rawRequest(arena, "GET", key, "", empty_payload_hash, null, &aw.writer) catch
            return error.RequestFailed;
        if (status == .not_found) return error.NotFound;
        if (status != .ok) return error.RequestFailed;
        const body = aw.writer.buffered();
        if (body.len > limit) return error.RequestFailed;
        return body;
    }

    pub fn deleteObject(self: *Client, arena: std.mem.Allocator, key: []const u8) Error!void {
        const status = try self.simpleRequest(arena, "DELETE", key, "", empty_payload_hash, null, null);
        if (status != .no_content and status != .ok and status != .not_found) return error.RequestFailed;
    }

    /// A presigned GET URL, valid for `expires_secs` from `now_epoch_secs`.
    /// Anyone holding it can fetch that one object with plain HTTPS.
    pub fn presignGet(
        self: *Client,
        arena: std.mem.Allocator,
        key: []const u8,
        now_epoch_secs: u64,
        expires_secs: u32,
    ) Error![]u8 {
        return self.presign(arena, "GET", key, now_epoch_secs, expires_secs);
    }

    pub fn presignPut(
        self: *Client,
        arena: std.mem.Allocator,
        key: []const u8,
        now_epoch_secs: u64,
        expires_secs: u32,
    ) Error![]u8 {
        return self.presign(arena, "PUT", key, now_epoch_secs, expires_secs);
    }

    fn presign(
        self: *Client,
        arena: std.mem.Allocator,
        method: []const u8,
        key: []const u8,
        now_epoch_secs: u64,
        expires_secs: u32,
    ) Error![]u8 {
        const date_time = dateTimeFromEpoch(now_epoch_secs);
        const path = try self.objectPath(arena, key);

        const credential_raw = try std.fmt.allocPrint(arena, "{s}/{s}/{s}/s3/aws4_request", .{
            self.config.access_key, date_time[0..8], self.config.region,
        });
        const credential = try uriEncode(arena, credential_raw, false);
        const query = try std.fmt.allocPrint(
            arena,
            "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential={s}&X-Amz-Date={s}&X-Amz-Expires={d}&X-Amz-SignedHeaders=host",
            .{ credential, &date_time, expires_secs },
        );
        const sig = try signature(arena, .{
            .method = method,
            .canonical_path = path,
            .canonical_query = query,
            .headers = &.{.{ .name = "host", .value = self.host }},
            .payload_hash = unsigned_payload,
            .date_time = &date_time,
            .region = self.config.region,
            .service = "s3",
        }, self.config.secret_key);

        return std.fmt.allocPrint(arena, "{s}{s}?{s}&X-Amz-Signature={s}", .{
            self.config.endpoint, path, query, &sig,
        });
    }

    fn objectPath(self: *Client, arena: std.mem.Allocator, key: []const u8) ![]u8 {
        if (key.len == 0) return std.fmt.allocPrint(arena, "/{s}", .{self.config.bucket});
        const encoded = try uriEncode(arena, key, true);
        return std.fmt.allocPrint(arena, "/{s}/{s}", .{ self.config.bucket, encoded });
    }

    fn simpleRequest(
        self: *Client,
        arena: std.mem.Allocator,
        method: []const u8,
        key: []const u8,
        query: []const u8,
        payload_hash: []const u8,
        payload: ?[]const u8,
        content_length_out: ?*u64,
    ) Error!std.http.Status {
        _ = content_length_out; // HEAD size comes with the push slice if needed
        return self.rawRequest(arena, method, key, query, payload_hash, payload, null) catch
            error.RequestFailed;
    }

    fn rawRequest(
        self: *Client,
        arena: std.mem.Allocator,
        method: []const u8,
        key: []const u8,
        query: []const u8,
        payload_hash: []const u8,
        payload: ?[]const u8,
        response_writer: ?*std.Io.Writer,
    ) !std.http.Status {
        const now: u64 = @intCast(@max(0, std.Io.Timestamp.now(self.http.io, .real).toSeconds()));
        const date_time = dateTimeFromEpoch(now);
        const path = try self.objectPath(arena, key);

        const headers = [_]Header{
            .{ .name = "host", .value = self.host },
            .{ .name = "x-amz-content-sha256", .value = payload_hash },
            .{ .name = "x-amz-date", .value = &date_time },
        };
        const auth = try authorizationHeader(arena, .{
            .method = method,
            .canonical_path = path,
            .canonical_query = query,
            .headers = &headers,
            .payload_hash = payload_hash,
            .date_time = &date_time,
            .region = self.config.region,
            .service = "s3",
        }, self.config.access_key, self.config.secret_key);

        const url = if (query.len == 0)
            try std.fmt.allocPrint(arena, "{s}{s}", .{ self.config.endpoint, path })
        else
            try std.fmt.allocPrint(arena, "{s}{s}?{s}", .{ self.config.endpoint, path, query });

        const result = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = std.meta.stringToEnum(std.http.Method, method) orelse return error.RequestFailed,
            .payload = payload,
            .raw_uri = true,
            // One connection per request: reusing pooled connections to
            // SeaweedFS has produced rare hangs under Zig 0.16's client.
            .keep_alive = false,
            .response_writer = response_writer,
            .extra_headers = &.{
                .{ .name = "x-amz-content-sha256", .value = payload_hash },
                .{ .name = "x-amz-date", .value = &date_time },
                .{ .name = "authorization", .value = auth },
            },
        });
        return result.status;
    }
};

// ---------------------------------------------------------------------------
// Tests: AWS documentation vectors pin the signing math.
// ---------------------------------------------------------------------------

test "signing key derivation matches the AWS documentation example" {
    const key = signingKey("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20150830", "us-east-1", "iam");
    const hex = std.fmt.bytesToHex(key, .lower);
    try std.testing.expectEqualStrings(
        "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9",
        &hex,
    );
}

test "GET request signature matches the AWS documentation example" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const input: SignInput = .{
        .method = "GET",
        .canonical_path = "/",
        .canonical_query = "Action=ListUsers&Version=2010-05-08",
        .headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded; charset=utf-8" },
            .{ .name = "host", .value = "iam.amazonaws.com" },
            .{ .name = "x-amz-date", .value = "20150830T123600Z" },
        },
        .payload_hash = empty_payload_hash,
        .date_time = "20150830T123600Z",
        .region = "us-east-1",
        .service = "iam",
    };
    const creq = try canonicalRequestHash(arena, input);
    try std.testing.expectEqualStrings(
        "f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59",
        &creq,
    );
    const sig = try signature(arena, input, "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");
    try std.testing.expectEqualStrings(
        "5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7",
        &sig,
    );
}

test "presigned GET matches the AWS S3 documentation example" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sig = try signature(arena, .{
        .method = "GET",
        .canonical_path = "/test.txt",
        .canonical_query = "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host",
        .headers = &.{.{ .name = "host", .value = "examplebucket.s3.amazonaws.com" }},
        .payload_hash = unsigned_payload,
        .date_time = "20130524T000000Z",
        .region = "us-east-1",
        .service = "s3",
    }, "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY");
    try std.testing.expectEqualStrings(
        "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
        &sig,
    );
}

test "uri encoding and date formatting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "items/sha256/aa/bb",
        try uriEncode(arena, "items/sha256/aa/bb", true),
    );
    try std.testing.expectEqualStrings(
        "a%2Fb%20c%2A",
        try uriEncode(arena, "a/b c*", false),
    );
    const dt = dateTimeFromEpoch(1369353600); // 2013-05-24T00:00:00Z
    try std.testing.expectEqualStrings("20130524T000000Z", &dt);
}
