//! Only the authorization URL is public. The returned callback is borrowed
//! for one private action and must never be copied into a View or event.
const std = @import("std");

pub const max_authorization_url_bytes = 1024;
pub const max_callback_bytes = 4096;
pub const Action = union(enum) { start, cancel, submit: []const u8 };
pub const Status = enum { idle, pending, succeeded, failed, canceled };
pub const Failure = enum { unavailable, denied, expired, busy, invalid_response, storage, other };

/// Accept only the public side of the browser flow, not arbitrary URLs from
/// the wire. In particular, callback and token parameters aren't display data.
pub fn validAuthorizationUrl(url: []const u8) bool {
    const prefix = "https://auth.openai.com/oauth/authorize?";
    if (url.len > max_authorization_url_bytes or !std.mem.startsWith(u8, url, prefix)) return false;
    for (url) |c| if (c < 0x21 or c > 0x7e or c == '#' or c == '\\') return false;
    var fields = std.mem.splitScalar(u8, url[prefix.len..], '&');
    while (fields.next()) |field| {
        const i = std.mem.findScalar(u8, field, '=') orelse return false;
        if (i + 1 == field.len) return false;
        const public = [_][]const u8{ "response_type", "client_id", "redirect_uri", "scope", "code_challenge", "code_challenge_method", "state", "id_token_add_organizations", "codex_cli_simplified_flow", "originator" };
        for (public) |key| {
            if (std.mem.eql(u8, key, field[0..i])) break;
        } else return false;
    }
    return true;
}

pub const View = struct {
    generation: u64 = 0,
    status: Status = .idle,
    url: [max_authorization_url_bytes]u8 = @splat(0),
    url_len: u16 = 0,
    failure: ?Failure = null,

    pub fn authorizationUrl(self: *const View) []const u8 {
        return self.url[0..self.url_len];
    }
};
