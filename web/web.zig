//! Web viewer embedded in the binary: the host serves it over HTTP.
pub const index_html = @embedFile("index.html");
pub const viewer_js = @embedFile("viewer.js");
