//! Веб-зритель, встроенный в бинарник: хост отдаёт его по HTTP.
pub const index_html = @embedFile("index.html");
pub const viewer_js = @embedFile("viewer.js");
