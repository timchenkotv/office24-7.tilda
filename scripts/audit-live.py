#!/usr/bin/env python3
import argparse
import html
import json
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlsplit

RESOURCE_ATTRS = {
    "src",
    "poster",
    "data-src",
    "data-original",
    "data-img-zoom-url",
    "data-content-cover-bg",
    "data-bg",
    "data-lazy-src",
}
CSS_URL_RE = re.compile(r"url\(\s*['\"]?([^)'\"\s]+)", re.I)
ABSOLUTE_URL_RE = re.compile(r"https?://[^\s\"'<>\\]+", re.I)
SCRIPT_TAG_RE = re.compile(r"<script\b", re.I)
FORM_GUARD_RE = re.compile(r'<script\b[^>]*\bid=["\']office24-static-form-guard["\']', re.I)
TILDA_STAT_RE = re.compile(
    r"<script\b[^>]*>\s*if \(! window\.mainTracker\)(?:(?!</script>).)*</script>",
    re.I | re.S,
)


def allowed_asset_host(host):
    host = host.lower()
    return (
        host == "office24-7.ru"
        or host == "www.office24-7.ru"
        or host.endswith(".tildacdn.com")
        or host.endswith(".tildacdn.net")
        or host.endswith(".tildacdn.info")
        or host.endswith(".tilda.ws")
        or host == "tilda.ws"
        or host in {"fonts.googleapis.com", "fonts.gstatic.com"}
    )


class LiveParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.assets = []
        self.inline_css = []
        self.title_parts = []
        self.in_title = False
        self.record_count = 0
        self.script_count = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "title":
            self.in_title = True
        if tag == "script":
            self.script_count += 1
        if "data-record-type" in attrs:
            self.record_count += 1
        for name in RESOURCE_ATTRS:
            if attrs.get(name):
                self.assets.append(attrs[name])
        if tag == "script" and attrs.get("src"):
            self.assets.append(attrs["src"])
        if tag == "link" and attrs.get("href") and attrs.get("rel", "").lower() not in {"preconnect", "dns-prefetch"}:
            self.assets.append(attrs["href"])
        if "srcset" in attrs:
            for item in attrs["srcset"].split(","):
                if item.strip():
                    self.assets.append(item.strip().split()[0])
        if "style" in attrs:
            self.inline_css.append(attrs["style"])
        if tag == "meta" and (
            "image" in attrs.get("property", "").lower()
            or attrs.get("itemprop", "").lower() == "image"
        ):
            if attrs.get("content"):
                self.assets.append(attrs["content"].rstrip("}"))

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False

    def handle_data(self, data):
        if self.in_title:
            self.title_parts.append(data)

    @property
    def title(self):
        return "".join(self.title_parts).strip()


def fetch(url):
    proc = subprocess.run(
        [
            "curl",
            "-fsSL",
            "--compressed",
            "--retry",
            "3",
            "--retry-delay",
            "1",
            "--max-time",
            "90",
            "-A",
            "Mozilla/5.0 CodexOffice24Audit/1.0",
            url,
        ],
        capture_output=True,
    )
    if proc.returncode:
        return url, None, proc.stderr.decode("utf-8", errors="replace").strip()
    return url, proc.stdout.decode("utf-8", errors="replace"), None


def local_page_path(root, url, mapping):
    web_path = mapping.get(url)
    if web_path:
        return root / web_path.lstrip("/")
    path = urlsplit(url).path
    candidate = root / path.lstrip("/")
    return candidate if path.endswith(".html") else candidate / "index.html"


def extract_live_assets(page_url, text, parser):
    refs = list(parser.assets)
    for css in parser.inline_css:
        refs.extend(CSS_URL_RE.findall(css))
    unescaped = text.replace("\\/", "/")
    refs.extend(ABSOLUTE_URL_RE.findall(unescaped))

    assets = set()
    for raw in refs:
        raw = html.unescape(raw.strip()).rstrip("),;}")
        if not raw or raw.startswith(("#", "data:", "javascript:", "mailto:", "tel:")):
            continue
        absolute = urljoin(page_url, raw)
        parsed = urlsplit(absolute)
        if not allowed_asset_host(parsed.netloc):
            continue
        if parsed.netloc.lower().startswith(("forms.", "stat.", "feeds.")):
            continue
        path = parsed.path
        if parsed.netloc in {"office24-7.ru", "www.office24-7.ru"} and not re.search(r"\.[A-Za-z0-9]{1,8}$", path):
            continue
        if not path or path == "/":
            continue
        assets.add(absolute)
    return assets


def parse_local(path):
    text = path.read_text("utf-8", errors="replace")
    parser = LiveParser()
    parser.feed(text)
    return parser, text


def functional_script_count(text):
    """Ignore the local form guard and the removed Tilda telemetry loader."""
    return (
        len(SCRIPT_TAG_RE.findall(text))
        - len(FORM_GUARD_RE.findall(text))
        - len(TILDA_STAT_RE.findall(text))
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="www")
    parser.add_argument("--sitemap-pages", default="reports/sitemap-pages.txt")
    parser.add_argument("--url-map", default="reports/url-map.tsv")
    parser.add_argument("--output", default="reports/live-audit.json")
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()

    root = Path(args.root).resolve()
    urls = [line.strip() for line in Path(args.sitemap_pages).read_text().splitlines() if line.strip()]
    mapping = {}
    for line in Path(args.url_map).read_text().splitlines():
        source, target = line.split("\t", 1)
        mapping[source] = target

    responses = {}
    fetch_errors = []
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {executor.submit(fetch, url): url for url in urls}
        for future in as_completed(futures):
            url, text, error = future.result()
            if error:
                fetch_errors.append({"url": url, "error": error})
            else:
                responses[url] = text

    missing_assets = []
    structure_mismatches = []
    discovered_assets = set()
    for url, text in responses.items():
        live = LiveParser()
        live.feed(text)
        local_path = local_page_path(root, url, mapping)
        if not local_path.exists():
            structure_mismatches.append({"url": url, "reason": "missing local page"})
            continue
        local, local_text = parse_local(local_path)
        if live.title != local.title:
            structure_mismatches.append({"url": url, "reason": "title differs", "live": live.title, "local": local.title})
        if live.record_count != local.record_count:
            structure_mismatches.append({"url": url, "reason": "Tilda block count differs", "live": live.record_count, "local": local.record_count})
        live_scripts = functional_script_count(text)
        local_scripts = functional_script_count(local_text)
        if live_scripts != local_scripts:
            structure_mismatches.append({"url": url, "reason": "functional script count differs", "live": live_scripts, "local": local_scripts})

        for asset in extract_live_assets(url, text, live):
            discovered_assets.add(asset)
            web_path = mapping.get(asset)
            if web_path is None:
                no_fragment = asset.split("#", 1)[0]
                web_path = mapping.get(no_fragment)
            if web_path is None:
                missing_assets.append({"page": url, "asset": asset, "reason": "not in URL map"})
                continue
            local_asset = root / web_path.lstrip("/")
            if not local_asset.exists():
                missing_assets.append({"page": url, "asset": asset, "reason": "mapped file missing", "target": str(local_asset)})

    unique_missing = list({(item["asset"], item["reason"]): item for item in missing_assets}.values())
    result = {
        "summary": {
            "sitemap_pages": len(urls),
            "live_pages_fetched": len(responses),
            "live_page_fetch_errors": len(fetch_errors),
            "live_assets_discovered": len(discovered_assets),
            "missing_local_assets": len(unique_missing),
            "page_structure_mismatches": len(structure_mismatches),
        },
        "live_page_fetch_errors": fetch_errors,
        "missing_local_assets": unique_missing,
        "page_structure_mismatches": structure_mismatches,
    }
    Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result["summary"], ensure_ascii=False, indent=2))
    if fetch_errors or unique_missing or structure_mismatches:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
