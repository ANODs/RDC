//! Web viewer embedded in the binary: the host serves it over HTTP.
pub const index_html = @embedFile("index.html");
pub const viewer_js = @embedFile("viewer.js");
/// The favicon and the home-screen icon on phones (tools/make_icons.sh).
pub const icon_png = @embedFile("icon.png");
