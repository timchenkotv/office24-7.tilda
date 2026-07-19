#!/usr/bin/env python3
import argparse
import json
import re
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

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
URL_ATTRS = RESOURCE_ATTRS | {"href"}
CSS_URL_RE = re.compile(r"url\(\s*['\"]?([^)'\"\s]+)", re.I)


class RefParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.refs = []
        self.inline_css = []
        self.forms = 0
        self.has_form_guard = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "form":
            self.forms += 1
        if attrs.get("id") == "office24-static-form-guard":
            self.has_form_guard = True
        for name in URL_ATTRS:
            value = attrs.get(name)
            if value:
                self.refs.append((tag, name, value))
        if "srcset" in attrs:
            for item in attrs["srcset"].split(","):
                value = item.strip().split()[0] if item.strip() else ""
                if value:
                    self.refs.append((tag, "srcset", value))
        if "style" in attrs:
            self.inline_css.append(attrs["style"])
        if tag == "meta" and (
            "image" in attrs.get("property", "").lower()
            or attrs.get("itemprop", "").lower() == "image"
        ):
            value = attrs.get("content")
            if value:
                self.refs.append((tag, "content", value))


def expected_path(root: Path, page_url: str, ref: str):
    value = ref.strip()
    if not value or value.startswith(("#", "data:", "javascript:", "mailto:", "tel:")):
        return None
    if value.startswith("//"):
        return None
    parsed = urlsplit(value)
    if parsed.scheme in {"http", "https"}:
        return None
    absolute = urlsplit(urljoin(page_url, value.replace("\\", "/")))
    path = unquote(absolute.path)
    candidate = root / path.lstrip("/")
    if path.endswith("/"):
        candidate /= "index.html"
    elif not candidate.suffix and not candidate.is_file():
        candidate /= "index.html"
    return candidate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="www")
    parser.add_argument("--sitemap-pages", default="reports/sitemap-pages.txt")
    parser.add_argument("--output", default="reports/local-audit.json")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    missing = []
    remote_tilda_resources = []
    external_hosts = Counter()
    reference_count = 0
    html_files = sorted(root.rglob("*.html"))
    pages_with_forms = 0
    forms_without_guard = []

    for html_file in html_files:
        text = html_file.read_text("utf-8", errors="replace")
        parser_obj = RefParser()
        parser_obj.feed(text)
        if parser_obj.forms:
            pages_with_forms += 1
            if not parser_obj.has_form_guard:
                forms_without_guard.append(str(html_file))

        web_path = "/" + html_file.relative_to(root).as_posix()
        if web_path.endswith("/index.html"):
            web_path = web_path[: -len("index.html")]
        page_url = "https://office24-7.ru" + web_path

        refs = list(parser_obj.refs)
        for css in parser_obj.inline_css:
            refs.extend(("style", "url", value) for value in CSS_URL_RE.findall(css))

        for tag, attr, ref in refs:
            reference_count += 1
            parsed = urlsplit(ref)
            if parsed.scheme in {"http", "https"} or ref.startswith("//"):
                host = parsed.netloc or urlsplit("https:" + ref).netloc
                external_hosts[host.lower()] += 1
                if "tilda" in host.lower() and (attr in RESOURCE_ATTRS or tag in {"script", "link", "img", "source", "video"}):
                    remote_tilda_resources.append({"file": str(html_file), "ref": ref})
                continue
            target = expected_path(root, page_url, ref)
            if target is not None and not target.exists():
                missing.append({"file": str(html_file), "ref": ref, "target": str(target)})

    for css_file in root.rglob("*.css"):
        text = css_file.read_text("utf-8", errors="replace")
        web_path = "/" + css_file.relative_to(root).as_posix()
        base_url = "https://office24-7.ru" + web_path
        for ref in CSS_URL_RE.findall(text):
            reference_count += 1
            parsed = urlsplit(ref)
            if parsed.scheme in {"http", "https"} or ref.startswith("//"):
                host = parsed.netloc or urlsplit("https:" + ref).netloc
                external_hosts[host.lower()] += 1
                if "tilda" in host.lower():
                    remote_tilda_resources.append({"file": str(css_file), "ref": ref})
                continue
            target = expected_path(root, base_url, ref)
            if target is not None and not target.exists():
                missing.append({"file": str(css_file), "ref": ref, "target": str(target)})

    sitemap_urls = [line.strip() for line in Path(args.sitemap_pages).read_text().splitlines() if line.strip()]
    missing_sitemap_pages = []
    for url in sitemap_urls:
        path = urlsplit(url).path
        candidate = root / path.lstrip("/")
        if path.endswith(".html"):
            expected = candidate
        else:
            expected = candidate / "index.html" if path else root / "index.html"
        if not expected.exists():
            missing_sitemap_pages.append({"url": url, "target": str(expected)})

    unique_missing = list({(item["file"], item["ref"], item["target"]): item for item in missing}.values())
    result = {
        "summary": {
            "html_files": len(html_files),
            "sitemap_pages": len(sitemap_urls),
            "missing_sitemap_pages": len(missing_sitemap_pages),
            "references_checked": reference_count,
            "missing_local_references": len(unique_missing),
            "remote_tilda_resources": len(remote_tilda_resources),
            "pages_with_forms": pages_with_forms,
            "forms_without_guard": len(forms_without_guard),
        },
        "missing_sitemap_pages": missing_sitemap_pages,
        "missing_local_references": unique_missing,
        "remote_tilda_resources": remote_tilda_resources,
        "forms_without_guard": forms_without_guard,
        "external_hosts": dict(external_hosts.most_common()),
    }
    Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result["summary"], ensure_ascii=False, indent=2))
    if missing_sitemap_pages or unique_missing or remote_tilda_resources or forms_without_guard:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
