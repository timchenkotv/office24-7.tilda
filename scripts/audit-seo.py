#!/usr/bin/env python3
import argparse
import json
import re
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit


PRIMARY_ORIGIN = "https://office24-7.ru"
LOC_RE = re.compile(r"<loc>(.*?)</loc>", re.I | re.S)


class SeoParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.canonical = ""
        self.description = ""
        self.og_url = ""
        self.robots = ""
        self.title_parts = []
        self.in_title = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "title":
            self.in_title = True
        if tag == "link" and "canonical" in attrs.get("rel", "").lower().split():
            self.canonical = attrs.get("href", "").strip()
        if tag == "meta":
            name = attrs.get("name", "").lower()
            prop = attrs.get("property", "").lower()
            content = attrs.get("content", "").strip()
            if name == "description":
                self.description = content
            elif name == "robots":
                self.robots = content
            elif prop == "og:url":
                self.og_url = content

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False

    def handle_data(self, data):
        if self.in_title:
            self.title_parts.append(data)

    @property
    def title(self):
        return "".join(self.title_parts).strip()


def page_path(root, url):
    path = urlsplit(url).path
    candidate = root / path.lstrip("/")
    return candidate if path.endswith(".html") else candidate / "index.html"


def normalized_path(url):
    path = urlsplit(url).path or "/"
    return path.rstrip("/") or "/"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="www")
    parser.add_argument("--robots", default="www/robots.txt")
    parser.add_argument("--sitemap-pages", default="reports/sitemap-pages.txt")
    parser.add_argument("--output", default="reports/seo-audit.json")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    pages = [line.strip() for line in Path(args.sitemap_pages).read_text().splitlines() if line.strip()]
    robots = Path(args.robots).read_text("utf-8", errors="replace")
    sitemap_refs = re.findall(r"^Sitemap:\s*(\S+)", robots, re.I | re.M)

    blockers = []
    warnings = []
    titles = {}
    descriptions = {}

    for sitemap_url in sitemap_refs:
        if not sitemap_url.startswith(PRIMARY_ORIGIN + "/"):
            blockers.append({"type": "foreign sitemap origin", "value": sitemap_url})
            continue
        sitemap_file = root / urlsplit(sitemap_url).path.lstrip("/")
        if not sitemap_file.exists():
            blockers.append({"type": "missing sitemap file", "value": sitemap_url})

    for sitemap_file in sorted(root.glob("sitemap*.xml")):
        text = sitemap_file.read_text("utf-8", errors="replace")
        for loc in LOC_RE.findall(text):
            loc = loc.strip()
            if not loc.startswith(PRIMARY_ORIGIN + "/") and loc != PRIMARY_ORIGIN:
                blockers.append({"type": "foreign sitemap URL", "file": str(sitemap_file), "value": loc})

    for url in pages:
        path = page_path(root, url)
        if not path.exists():
            blockers.append({"type": "missing sitemap page", "url": url})
            continue
        text = path.read_text("utf-8", errors="replace")
        seo = SeoParser()
        seo.feed(text)

        if not seo.title:
            blockers.append({"type": "missing title", "url": url})
        else:
            titles.setdefault(seo.title, []).append(url)
        if not seo.canonical:
            blockers.append({"type": "missing canonical", "url": url})
        elif not seo.canonical.startswith(PRIMARY_ORIGIN + "/") and seo.canonical != PRIMARY_ORIGIN:
            blockers.append({"type": "wrong canonical origin", "url": url, "value": seo.canonical})
        elif normalized_path(seo.canonical) != normalized_path(url):
            blockers.append({"type": "canonical path mismatch", "url": url, "value": seo.canonical})
        if not seo.og_url:
            warnings.append({"type": "missing og:url", "url": url})
        elif not seo.og_url.startswith(PRIMARY_ORIGIN + "/") and seo.og_url != PRIMARY_ORIGIN:
            blockers.append({"type": "wrong og:url origin", "url": url, "value": seo.og_url})
        if not seo.description:
            warnings.append({"type": "missing description", "url": url})
        else:
            descriptions.setdefault(seo.description, []).append(url)
        if "noindex" in seo.robots.lower():
            blockers.append({"type": "sitemap page is noindex", "url": url})

    staging_refs = []
    for path in root.rglob("*"):
        if path.is_file() and path.suffix.lower() in {".html", ".xml", ".txt", ".css", ".js"}:
            text = path.read_text("utf-8", errors="replace")
            if "site.office24-7.ru" in text:
                staging_refs.append(str(path))
    if staging_refs:
        blockers.append({"type": "staging domain references", "files": staging_refs})

    result = {
        "summary": {
            "sitemap_pages": len(pages),
            "robots_sitemaps": len(sitemap_refs),
            "seo_blockers": len(blockers),
            "seo_warnings": len(warnings),
            "duplicate_titles": sum(1 for value in titles.values() if len(value) > 1),
            "duplicate_descriptions": sum(1 for value in descriptions.values() if len(value) > 1),
        },
        "blockers": blockers,
        "warnings": warnings,
        "duplicate_titles": {key: value for key, value in titles.items() if len(value) > 1},
        "duplicate_descriptions": {key: value for key, value in descriptions.items() if len(value) > 1},
    }
    Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result["summary"], ensure_ascii=False, indent=2))
    if blockers:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
