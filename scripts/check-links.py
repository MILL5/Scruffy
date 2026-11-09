#!/usr/bin/env python3
"""Check local documentation and website references without network access."""
from html.parser import HTMLParser
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "docs/site"


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if "id" in values:
            self.ids.add(values["id"])
        for attribute in ("href", "src"):
            if attribute in values:
                self.links.append(values[attribute])


def check():
    files = [ROOT / "README.md", *sorted((ROOT / "docs").rglob("*.md"))]
    files += sorted(SITE.rglob("*.html"))
    failures = []
    checked = 0
    for source in files:
        content = source.read_text()
        if source.suffix == ".html":
            parsed = Links()
            parsed.feed(content)
            links = parsed.links
        else:
            links = re.findall(r"!?\[[^\]]*\]\(([^\s)]+)(?:\s+\"[^\"]*\")?\)", content)
        for link in links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                continue
            path = unquote(url.path)
            if path.startswith("/Scruffy/"):
                target = SITE / path.removeprefix("/Scruffy/")
            elif path.startswith("/"):
                failures.append(f"{source.relative_to(ROOT)}: unsupported root-relative link {link}")
                continue
            else:
                target = source.parent / path if path else source
            if target.is_dir():
                target = target / "index.html" if source.suffix == ".html" else target
            checked += 1
            if not target.exists():
                failures.append(f"{source.relative_to(ROOT)}: missing {link}")
            elif target.suffix == ".html" and url.fragment:
                destination = Links()
                destination.feed(target.read_text())
                if unquote(url.fragment) not in destination.ids:
                    failures.append(f"{source.relative_to(ROOT)}: missing anchor {link}")
    if failures:
        print("\n".join(failures))
        return 1
    print(f"Checked {checked} local references across {len(files)} documentation/site files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(check())
