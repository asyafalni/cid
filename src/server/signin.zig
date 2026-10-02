//! "Sign in with GitLab" for the dashboard (docs/dashboard.md, Sign-in;
//! docs/access.md): OAuth with scope `read_user`, the same `gitlab:<id>`
//! account the SSH front door maps keys to, so the dashboard and the CLI
//! always agree on who may see what. Permission is never stored here: the
//! session only says who you are, and every request is checked against the
//! `access` table, which GitLab sync keeps true.
//!
//! The session is nilo's `Session(T)` (ADR 033 there): sealed into one
//! encrypted, signed cookie, `__Host-session`, HttpOnly, Secure,
//! SameSite=Lax, twelve hours. Nothing is kept on the server. Outbound
//! calls to GitLab go through `nilo_fetch`, so a slow GitLab costs a fiber
//! a deadline, never a worker thread. PKCE (S256) and a state value guard
//! the round trip; both ride in the session while it is in flight.

const std = @import("std");
const nilo = @import("nilo_http");
const fetch = @import("nilo_fetch");
const api = @import("api.zig");

pub const Config = struct {
    /// e.g. https://gitlab.com (CID_GITLAB_URL).
    gitlab_url: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    /// Where browsers reach this server (CID_PUBLIC_URL); the redirect URI
    /// registered on the GitLab application is `<public_url>/auth/gitlab/callback`.
    public_url: []const u8,
};

/// What the session cookie holds. Fixed-size by nilo's rule, so a GitLab
/// user id rather than an account string; `gitlab:<id>` is rebuilt per use.
pub const Signed = struct {
    /// The signed-in GitLab user, 0 when nobody is.
    gitlab_user: u64 = 0,
    /// The OAuth round trip in flight: the state echoed back, and the
    /// PKCE verifier the token exchange proves possession of.
    state: [state_len]u8 = @splat(0),
    verifier: [verifier_len]u8 = @splat(0),
};

pub const Session = nilo.Session(Signed);

/// Twelve hours (docs/dashboard.md): sealed inside the cookie too, so a
/// copied cookie stops opening on time whatever the browser does.
pub const session_secs: i64 = 12 * 60 * 60;
/// The sign-in round trip: long enough to type a GitLab password.
const pending_secs: i64 = 10 * 60;

const state_len = 22; // base64url of 16 random bytes
const verifier_len = 43; // base64url of 32 random bytes, RFC 7636's minimum

pub fn accountOf(gitlab_user: u64, arena: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(arena, "gitlab:{d}", .{gitlab_user});
}

/// GET /auth/gitlab: start the round trip and send the browser to GitLab.
pub fn start(c: *nilo.Ctx, s: Session, cfg: *const Config) !void {
    var pending: Signed = .{};
    const state_raw = try c.entropy(16);
    _ = std.base64.url_safe_no_pad.Encoder.encode(&pending.state, &state_raw);
    const verifier_raw = try c.entropy(32);
    _ = std.base64.url_safe_no_pad.Encoder.encode(&pending.verifier, &verifier_raw);
    try s.setWith(pending, .{ .max_age = pending_secs });

    const challenge = challengeOf(&pending.verifier);
    const location = try fetch.withQuery(c, try std.fmt.allocPrint(c.arena(), "{s}/oauth/authorize", .{cfg.gitlab_url}), .{
        .client_id = cfg.client_id,
        .redirect_uri = try redirectUri(c.arena(), cfg),
        .response_type = "code",
        .scope = "read_user",
        .state = @as([]const u8, &pending.state),
        .code_challenge = @as([]const u8, &challenge),
        .code_challenge_method = "S256",
    });
    try c.redirect(303, location);
}

/// GET /auth/gitlab/callback: check the state, trade the code for a token,
/// ask GitLab who this is, and seal the session. Any failure lands on the
/// sign-in page with a reason a person can act on; no token is logged.
pub fn callback(c: *nilo.Ctx, s: Session, cfg: *const Config, client: *fetch.Client, deps: *api.Deps) !void {
    const pending = s.get() orelse return fail(c, "expired");
    const code = (c.query("code") orelse return fail(c, "denied")).view();
    const state = (c.query("state") orelse return fail(c, "state")).view();
    if (!sameState(&pending.state, state)) return fail(c, "state");

    const form = try fetch.withQuery(c, "", .{
        .grant_type = "authorization_code",
        .client_id = cfg.client_id,
        .client_secret = cfg.client_secret,
        .code = code,
        .redirect_uri = try redirectUri(c.arena(), cfg),
        .code_verifier = @as([]const u8, &pending.verifier),
    });
    const token_url = try std.fmt.allocPrint(c.arena(), "{s}/oauth/token", .{cfg.gitlab_url});
    const token_res = client.post(c, token_url, form[1..], .{
        .headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }},
    }) catch return fail(c, "gitlab");
    if (!token_res.ok()) {
        std.log.warn("gitlab sign-in: the token exchange answered {d}", .{@intFromEnum(token_res.status)});
        return fail(c, "gitlab");
    }
    const Token = struct { access_token: []const u8 };
    const token = token_res.json(Token, c) catch return fail(c, "gitlab");

    const bearer = try std.fmt.allocPrint(c.arena(), "Bearer {s}", .{token.access_token});
    const user_url = try std.fmt.allocPrint(c.arena(), "{s}/api/v4/user", .{cfg.gitlab_url});
    const user_res = client.get(c, user_url, .{
        .headers = &.{.{ .name = "authorization", .value = bearer }},
    }) catch return fail(c, "gitlab");
    if (!user_res.ok()) return fail(c, "gitlab");
    const User = struct { id: u64, username: []const u8 = "", name: []const u8 = "" };
    const user = user_res.json(User, c) catch return fail(c, "gitlab");

    // The account the SSH front door would map this person's keys to.
    // Access is not granted here — sync and owners do that — so a GitLab
    // user nobody gave a dataset to signs in and sees an empty home.
    const account = try accountOf(user.id, c.arena());
    _ = deps.db.exec(
        c,
        "INSERT INTO accounts (account_id, display_name, source, synced_at) VALUES ($1, $2, 'gitlab', now()) " ++
            "ON CONFLICT (account_id) DO UPDATE SET display_name = excluded.display_name",
        .{ account, if (user.name.len > 0) user.name else user.username },
    ) catch return fail(c, "server");

    try s.setWith(.{ .gitlab_user = user.id }, .{ .max_age = session_secs });
    try c.redirect(303, "/");
}

/// POST /auth/signout. A POST, so a link on another site cannot sign
/// anybody out; SameSite=Lax already keeps it from carrying the cookie.
pub fn signout(c: *nilo.Ctx, s: Session) !void {
    try s.clear();
    try c.redirect(303, "/signin");
}

fn fail(c: *nilo.Ctx, why: []const u8) !void {
    const to = try std.fmt.allocPrint(c.arena(), "/signin?error={s}", .{why});
    try c.redirect(303, to);
}

fn redirectUri(arena: std.mem.Allocator, cfg: *const Config) ![]const u8 {
    const base = std.mem.trimEnd(u8, cfg.public_url, "/");
    return std.fmt.allocPrint(arena, "{s}/auth/gitlab/callback", .{base});
}

/// RFC 7636 S256: base64url(sha256(verifier)), no padding.
pub fn challengeOf(verifier: *const [verifier_len]u8) [43]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var out: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&out, &digest);
    return out;
}

/// The state that came back is the one this browser was sent with, in
/// constant time; an all-zero pending state (no round trip started)
/// matches nothing.
pub fn sameState(pending: *const [state_len]u8, got: []const u8) bool {
    if (got.len != state_len) return false;
    if (std.mem.allEqual(u8, pending, 0)) return false;
    var diff: u8 = 0;
    for (pending, got) |a, b| diff |= a ^ b;
    return diff == 0;
}

test "PKCE S256 matches RFC 7636's own example" {
    const verifier: *const [43]u8 = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &challengeOf(verifier));
}

test "the state check refuses a missing round trip, a wrong value and a short one" {
    var pending: [state_len]u8 = @splat(0);
    try std.testing.expect(!sameState(&pending, &pending)); // nothing started
    @memcpy(&pending, "abcdefghijklmnopqrstuv");
    try std.testing.expect(sameState(&pending, "abcdefghijklmnopqrstuv"));
    try std.testing.expect(!sameState(&pending, "abcdefghijklmnopqrstuw"));
    try std.testing.expect(!sameState(&pending, "abc"));
}

test "a session fits a cookie and names the account the SSH door uses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("gitlab:4242", try accountOf(4242, arena_state.allocator()));
    _ = Session; // its size is checked while compiling (nilo refuses an oversized cookie)
}
