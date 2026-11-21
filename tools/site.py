"""Builds what GitHub Pages serves into _site/: the viewer and the landing page.

    python3 tools/site.py                 # build
    python3 tools/site.py --offline       # build without asking GitHub for releases
    python3 tools/site.py --serve 4173    # build, serve, rebuild when a source changes

    /            the viewer (web/): every link from an RDC window opens here, as "/#<code>-<key>".
                 Without a link in the address it sends the visitor on to the landing page.
    /en/ /ru/ /zh/   the landing page (site/), one template and one strings file per language

Every language must have the same keys, and the template may only use keys that exist.
Template syntax:  {{key}} a string,  {{@name}} a build value,  {{@inc:file}} a file from
site/src placed inline.

Releases: the latest version, its files and the download counts come from the GitHub API at
build time (GITHUB_TOKEN is used when set). When that fails, the version of build.zig.zon and
the file names of the release workflow are used, without sizes and counts. The page asks again
when it opens. Standard library only.
"""

import functools
import html
import http.server
import json
import os
import pathlib
import re
import shutil
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
SRC = SITE / "src"
WEB = ROOT / "web"
OUT = ROOT / "_site"

LANGS = ["en", "ru", "zh"]
LOCALES = {"en": "en_US", "ru": "ru_RU", "zh": "zh_CN"}
# A release's files by system; "{v}" is the version. Keep in sync with site/src/app.js and site/worker.
SYSTEMS = {"mac": "RDC-{v}-macos-arm64.zip", "win": "RDC.exe", "linux": "rdc-linux-x86_64", "mcp": "rdc-mcp.mcpb"}

# The viewer's page with no link in the address is a visitor, not a session: on to the landing
# page in their language — a saved choice, then the browser's languages. A browser agent that
# came for the page's WebMCP tools stays.
DETECT = """<script>(function(){try{if(location.hash.length>1||document.modelContext||navigator.modelContext)return;
var L=['en','ru','zh'],l=null,s=localStorage.getItem('rdc-lang');if(L.indexOf(s)>=0)l=s;
if(!l){var n=navigator.languages||[navigator.language||''];for(var i=0;i<n.length&&!l;i++){var c=String(n[i]).toLowerCase().slice(0,2);if(c==='ru'||c==='be'||c==='kk')l='ru';else if(c==='zh')l='zh';else if(c==='en')l='en'}}
location.replace((l||'en')+'/')}catch(e){}})();</script>"""


def fail(message: str) -> None:
    sys.exit(f"site: {message}")


def version() -> str:
    m = re.search(r'^\s*\.version = "([^"]+)"', (ROOT / "build.zig.zon").read_text(), re.M)
    if not m:
        fail("no version in build.zig.zon")
    return m.group(1)


def vkey(v: str) -> tuple:
    return tuple(int(x) for x in v.split("."))


def normalize(releases: list) -> dict | None:
    """GitHub's release list -> {version, files[system], downloads}."""
    downloads = {"total": 0, **{s: 0 for s in SYSTEMS}}
    best, files = None, {}
    for rel in releases:
        m = re.fullmatch(r"v(\d+\.\d+\.\d+)", rel.get("tag_name", ""))
        if not m or rel.get("draft") or rel.get("prerelease"):
            continue
        ver = m.group(1)
        for asset in rel.get("assets", []):
            system = next((s for s, name in SYSTEMS.items() if asset["name"] == name.format(v=ver)), None)
            if not system:
                continue
            downloads[system] += asset.get("download_count", 0)
            if system != "mcp":
                downloads["total"] += asset.get("download_count", 0)
            if best is None or vkey(ver) > vkey(best):
                best, files = ver, {}
            if ver == best:
                files[system] = {"url": asset["browser_download_url"], "size": asset["size"]}
    if best is None or any(s not in files for s in ("mac", "win", "linux")):
        return None
    return {"version": best, "files": files, "downloads": downloads}


def fetch_releases(repo: str) -> dict | None:
    req = urllib.request.Request(
        f"https://api.github.com/repos/{repo}/releases?per_page=100",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "site-build"},
    )
    if os.environ.get("GITHUB_TOKEN"):
        req.add_header("Authorization", "Bearer " + os.environ["GITHUB_TOKEN"])
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return normalize(json.load(r))
    except Exception as e:  # no network, no release yet
        print(f"site: releases not read from GitHub ({e}); using build.zig.zon")
        return None


def fallback_releases(cfg: dict) -> dict:
    ver = version()
    files = {
        s: {"url": f"https://github.com/{cfg['repo']}/releases/download/v{ver}/{name.format(v=ver)}", "size": None}
        for s, name in SYSTEMS.items()
    }
    return {"version": ver, "files": files, "downloads": None}


def load_strings() -> dict:
    strings = {lang: json.loads((SITE / "i18n" / f"{lang}.json").read_text()) for lang in LANGS}
    keys = set(strings["en"])
    for lang in LANGS:
        diff = keys ^ set(strings[lang])
        if diff:
            fail(f"i18n/{lang}.json differs from en.json in: {', '.join(sorted(diff))}")
    return strings


def render(template: str, strings: dict, ctx: dict) -> str:
    used = set()

    def include(m: re.Match) -> str:
        return (SRC / m.group(1)).read_text()

    def value(m: re.Match) -> str:
        key = m.group(1)
        if key.startswith("@"):
            if key[1:] not in ctx:
                fail(f"unknown build value {{{{{key}}}}}")
            return ctx[key[1:]]
        if key not in strings:
            fail(f"unknown string {{{{{key}}}}}")
        used.add(key)
        return html.escape(strings[key], quote=True)

    text = re.sub(r"\{\{@inc:([\w.\-]+)\}\}", include, template)
    text = re.sub(r"\{\{(@?\w+)\}\}", value, text)
    unused = set(strings) - used - {"seo_features"}
    if unused:
        fail(f"strings nothing uses: {', '.join(sorted(unused))}")
    return text


def jsonld(cfg: dict, strings: dict, url: str, base: str, releases: dict) -> str:
    """What search engines read about the program: schema.org SoftwareApplication."""
    repo = "https://github.com/" + cfg["repo"]
    data = {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": "RDC",
        "alternateName": "Remote Desktop Control",
        "description": strings["description"],
        "featureList": strings["seo_features"].split(";"),
        "url": url,
        "image": f"{base}icon.png",
        "applicationCategory": "UtilitiesApplication",
        "applicationSubCategory": "Remote desktop",
        "operatingSystem": "macOS, Windows, Linux",
        "softwareVersion": releases["version"],
        "downloadUrl": f"{repo}/releases",
        "license": "https://www.apache.org/licenses/LICENSE-2.0",
        "isAccessibleForFree": True,
        "inLanguage": LANGS,
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "codeRepository": repo,
        "programmingLanguage": "Zig",
    }
    if releases.get("downloads") and releases["downloads"]["total"] > 0:
        data["interactionStatistic"] = {
            "@type": "InteractionCounter",
            "interactionType": "https://schema.org/DownloadAction",
            "userInteractionCount": releases["downloads"]["total"],
        }
    return json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")


def write_sitemap(base: str) -> None:
    links = "".join(f'<xhtml:link rel="alternate" hreflang="{l}" href="{base}{l}/"/>' for l in LANGS)
    links += f'<xhtml:link rel="alternate" hreflang="x-default" href="{base}en/"/>'
    urls = "".join(f"<url><loc>{base}{l}/</loc>{links}</url>" for l in LANGS)
    (OUT / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">'
        f"{urls}</urlset>\n"
    )
    (OUT / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {base}sitemap.xml\n")


def build(offline: bool = False, releases: dict | None = None) -> dict:
    cfg = json.loads((SITE / "site.json").read_text())
    strings = load_strings()
    if releases is None:
        releases = (None if offline else fetch_releases(cfg["repo"])) or fallback_releases(cfg)

    if OUT.exists():
        shutil.rmtree(OUT)
    # The viewer, as the host serves it, plus the way on for a visitor without a link.
    shutil.copytree(WEB, OUT, ignore=shutil.ignore_patterns("*.zig"))
    viewer = (OUT / "index.html").read_text()
    if '<meta charset="utf-8">' not in viewer:
        fail("web/index.html has no <meta charset> to put the redirect after")
    (OUT / "index.html").write_text(viewer.replace('<meta charset="utf-8">', '<meta charset="utf-8">\n' + DETECT, 1))

    base = cfg["base_url"].rstrip("/") + "/"
    template = (SRC / "index.html").read_text()
    for lang in LANGS:
        url = f"{base}{lang}/"
        data = {
            "lang": lang,
            "repo": cfg["repo"],
            "worker": cfg.get("worker_url", "").rstrip("/"),
            "releases": releases,
        }
        ctx = {
            "lang": lang,
            "base": base,
            "url": url,
            "home": "./",
            "og_locale": LOCALES[lang],
            "jsonld": jsonld(cfg, strings[lang], url, base, releases),
            "repo_url": "https://github.com/" + cfg["repo"],
            "version": releases["version"],
            "data": json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/"),
            "alternates": "\n".join(f'<link rel="alternate" hreflang="{l}" href="{base}{l}/">' for l in LANGS)
            + f'\n<link rel="alternate" hreflang="x-default" href="{base}en/">',
        }
        for l in LANGS:
            ctx["cur_" + l] = ' aria-current="true"' if l == lang else ""
        for s in SYSTEMS:
            ctx["file_" + s] = html.escape(releases["files"].get(s, {}).get("url", ctx["repo_url"] + "/releases"), quote=True)
        out = OUT / lang / "index.html"
        out.parent.mkdir(parents=True)
        out.write_text(render(template, strings[lang], ctx))

    write_sitemap(base)
    size = (OUT / "en" / "index.html").stat().st_size
    print(f"site: built the viewer and {len(LANGS)} pages, v{releases['version']}, en/index.html {size / 1024:.1f} KB")
    return releases


def sources_mtime() -> float:
    paths = [p for d in (SITE / "src", SITE / "i18n", WEB) for p in d.rglob("*") if p.is_file()]
    return max(p.stat().st_mtime for p in paths + [SITE / "site.json", ROOT / "build.zig.zon"])


def serve(port: int, offline: bool) -> None:
    state = {"releases": build(offline), "mtime": sources_mtime()}

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            mtime = sources_mtime()
            if mtime != state["mtime"]:
                state["mtime"] = mtime
                try:
                    build(releases=state["releases"])
                except SystemExit as e:
                    print(e)
            super().do_GET()

        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            super().end_headers()

        def log_message(self, *args):
            pass

    handler = functools.partial(Handler, directory=str(OUT))
    print(f"site: http://localhost:{port}/")
    http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()


if __name__ == "__main__":
    args = sys.argv[1:]
    offline = "--offline" in args
    if "--serve" in args:
        i = args.index("--serve")
        serve(int(args[i + 1]) if len(args) > i + 1 else 4173, offline)
    else:
        build(offline)
