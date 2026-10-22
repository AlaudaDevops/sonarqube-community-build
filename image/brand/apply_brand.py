#!/usr/bin/env python3
# Modified by Alauda on 2026-10-12.
"""Strip upstream SonarQube marks from a compiled SonarQube webapp and add the
trademark notice, at image build time.

    python3 apply_brand.py <webapp-dir>

Runs against both webapps we ship: /opt/sonarqube/web in the community-build
image and the sonarqube-community-branch-plugin sonarqube-webapp.zip in the
plugins image (the chart's install-plugins initContainer mounts the latter over
/opt/sonarqube/web, so it is the one users actually see by default).

Steps:
  1. Overwrite every upstream brand image (REPLACE) with the neutral assets.
  2. Rewrite the inline-SVG logo components compiled into js/echoes-*.js
     (title ids "logo.*") so they render images/logo.svg instead, and every
     other inline <svg> painted with the brand colour token
     "logos-colors-brand" (SonarQube for IDE / SonarLint pictograms).
  3. Inject alauda-trademark-footer.js into index.html.
  4. Drop source maps: they carry the original logo sources verbatim.

Each step is gated; any miss fails the build:
  gate 1 – every image file in the webapp is either replaced or explicitly
           kept (KEEP: third-party / illustration, not a SonarSource mark),
           so an upstream bump that adds a new logo file stops the build;
  gate 2 – no "logo.*" component, brand colour token, original logo path data
           or whale signature survives in any text asset;
  gate 3 – replaced bytes match the assets and the footer script is wired.
"""
import fnmatch
import gzip
import hashlib
import pathlib
import re
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
ASSETS = HERE / "assets"

# upstream path (relative to the webapp root) -> neutral asset
REPLACE = {
    "favicon.ico": "favicon.ico",
    "apple-touch-icon.png": "apple-touch-icon.png",
    "mstile-512x512.png": "mstile-512x512.png",
    "images/logo.svg": "logo.svg",
    "images/sonar-logo-white.svg": "logo.svg",
    "images/sonar-whale-white.svg": "logo.svg",
    "images/sonar-logo-horizontal.png": "logo-horizontal.png",
    "images/embed-doc/sq-icon.svg": "logo.svg",
}

# Image files that are not SonarSource marks: third-party ALM / CI logos
# (they identify the integration, not our product), generic illustrations and
# UI glyphs. Reviewed against webapp-assets 2025.6.0.36040 and
# sonarqube-community-branch-plugin 26.1.0.
KEEP = [
    "images/alm/*.svg",
    "images/tutorials/*.svg",
    "images/mode-tour/step*.png",
    "images/activity-chart.svg",
    "images/check.svg",
    "images/cross.svg",
    "images/embed-doc/x-icon-black.svg",
    "images/filter-large.svg",
    "images/hotspot-large.svg",
    "images/loading.gif",
    "images/saml.png",
    "images/sandboxed-issues-intro.png",
    "images/source-code.svg",
]

IMAGE_EXT = {".svg", ".png", ".ico", ".gif", ".jpg", ".jpeg", ".webp", ".avif", ".webmanifest"}
TEXT_EXT = {".js", ".css", ".html", ".json", ".svg", ".map", ".txt"}

# Path data of the upstream whale / SonarQube Cloud mark that is not inside a
# "logo.*" component (login marketing panel SVGs, embed-doc icon).
STATIC_SIGNATURES = ["M30.153 15.6497", "M11.939 13.282h-.756"]

FOOTER_JS = "alauda-trademark-footer.js"
FOOTER_TAG = '<script defer src="WEB_CONTEXT/%s"></script>' % FOOTER_JS
MARK_ATTR = "data-alauda-mark"
BRAND_TOKEN = '"logos-colors-brand"'
ICON_HREF = '(globalThis.__assetsPath?globalThis.__assetsPath("images/logo.svg"):"/images/logo.svg")'
# Prominent modification notices (GPL-3.0 §5(a), incorporated by LGPL-3.0) on
# the compiled files this step rewrites.
JS_NOTICE = ("/* Modified by Alauda on 2026-10-12: SonarQube logo components "
             "replaced with a neutral icon. */\n")
HTML_NOTICE = ("<!-- Modified by Alauda on 2026-10-12: trademark notice script added; "
               "brand images replaced. -->\n")

COMPONENT_HEAD = re.compile(
    r"(?P<name>[\w$]+)=(?P<react>[\w$]+)\.forwardRef\(\(\{hasText:[\w$]+=!1,(?:region:[\w$]+,)?"
    r"size:(?P<size>[\w$]+),\.\.\.(?P<rest>[\w$]+)\},(?P<ref>[\w$]+)\)=>\{"
)


def fail(msg):
    sys.exit("apply_brand: FAIL: " + msg)


def matching_brace(s, open_idx, opener="{", closer="}"):
    """Index of the bracket closing s[open_idx], skipping JS string literals."""
    depth, i, n = 0, open_idx, len(s)
    while i < n:
        c = s[i]
        if c in "\"'`":
            i += 1
            while i < n and s[i] != c:
                i += 2 if s[i] == "\\" else 1
        elif c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    fail("unbalanced %s%s in compiled JS" % (opener, closer))


def top_level_key(s, obj_start, obj_end, key):
    """Offset of `,key` at nesting depth 1 of the object literal s[obj_start:obj_end+1]."""
    depth, i = 0, obj_start
    while i < obj_end:
        c = s[i]
        if c in "\"'`":
            i += 1
            while i < obj_end and s[i] != c:
                i += 2 if s[i] == "\\" else 1
        elif c in "{[(":
            depth += 1
        elif c in "}])":
            depth -= 1
        elif depth == 1 and s.startswith("," + key, i):
            return i
        i += 1
    return -1


def patch_brand_token_svgs(js):
    """Rewrite inline <svg> elements painted with the upstream brand colour token.

    The echoes design system colours every SonarSource mark with the
    "logos-colors-brand" token (SonarQube for IDE pictograms, the SonarLint
    quick-fix icon, IDE-connection illustrations, ...). The element keeps its
    attributes and viewBox; its content becomes the neutral icon.
    Returns (patched source, number of elements rewritten).
    """
    out, pos, count = [], 0, 0
    for m in re.finditer(r'((?:[\w$]+\.)?[\w$]+)\("svg",\{', js):
        if m.start() < pos:
            continue
        call_open = m.start(1) + len(m.group(1))
        call_end = matching_brace(js, call_open, "(", ")")
        if BRAND_TOKEN not in js[call_open:call_end]:
            continue
        obj_start = m.end() - 1
        obj_end = matching_brace(js, obj_start)
        cut = top_level_key(js, obj_start, obj_end, "children:")
        if cut < 0:
            fail("brand svg without children at offset %d" % m.start())
        attrs = js[obj_start + 1:cut]
        vb = re.search(r'viewBox:"([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)"', attrs)
        if not vb:
            fail("brand svg without a literal viewBox at offset %d" % m.start())
        x, y, w, h = vb.groups()
        jsx = m.group(1)
        out.append(js[pos:m.start()])
        out.append(
            '%s("svg",{%s,"%s":"code-quality",children:[%s("image",{href:%s,x:%s,y:%s,width:%s,height:%s})]})'
            % (jsx, attrs, MARK_ATTR, jsx, ICON_HREF, x, y, w, h))
        pos = call_end + 1
        count += 1
    out.append(js[pos:])
    return "".join(out), count


def patch_logo_components(js):
    """Return (patched source, original path data, number of components)."""
    out, pos, signatures, count = [], 0, [], 0
    for m in COMPONENT_HEAD.finditer(js):
        if m.start() < pos:
            continue
        body_start = m.end() - 1
        body_end = matching_brace(js, body_start)
        body = js[body_start:body_end + 1]
        if 'id:"logo.' not in body:
            continue
        fn = re.search(r'([\w$]+)\(([\w$]+),\{fill:"none",ref:', body)
        jsx = re.search(r'([\w$]+)\("title",', body)
        if not fn or not jsx:
            fail("unexpected logo component shape for %s" % m.group("name"))
        signatures += [d[:24] for d in re.findall(r'\bd:"([^"]{24,})"', body)]
        replacement = (
            "{return %(jsxs)s(%(svg)s,{fill:\"none\",ref:%(ref)s,role:\"img\",size:%(size)s,"
            "viewBox:\"0 0 1024 1024\",xmlns:\"http://www.w3.org/2000/svg\",...%(rest)s,"
            "\"%(mark)s\":\"code-quality\",children:[%(jsx)s(\"title\",{children:\"Code Quality\"}),"
            "%(jsx)s(\"image\",{href:%(href)s,width:1024,height:1024})]})}"
        ) % {
            "jsxs": fn.group(1), "svg": fn.group(2), "jsx": jsx.group(1), "ref": m.group("ref"),
            "size": m.group("size"), "rest": m.group("rest"), "mark": MARK_ATTR, "href": ICON_HREF,
        }
        out.append(js[pos:body_start])
        out.append(replacement)
        pos = body_end + 1
        count += 1
    out.append(js[pos:])
    return "".join(out), signatures, count


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(web):
    if not (web / "index.html").is_file():
        fail("%s is not a SonarQube webapp (no index.html)" % web)

    # gate 1: exhaustive image inventory
    images = sorted(p.relative_to(web).as_posix() for p in web.rglob("*")
                    if p.is_file() and p.suffix.lower() in IMAGE_EXT)
    missing = [r for r in REPLACE if r not in images]
    if missing:
        fail("upstream brand files moved or renamed, update REPLACE: %s" % missing)
    unknown = [r for r in images if r not in REPLACE and not any(fnmatch.fnmatch(r, k) for k in KEEP)]
    if unknown:
        fail("unreviewed image files (add to REPLACE or KEEP): %s" % unknown)

    # step 1
    for rel, asset in REPLACE.items():
        shutil.copyfile(ASSETS / asset, web / rel)

    # step 2
    echoes = sorted((web / "js").glob("echoes-*.js"))
    if len(echoes) != 1:
        fail("expected exactly one js/echoes-*.js, found %s" % [p.name for p in echoes])
    src = echoes[0].read_text(encoding="utf-8")
    expected = len(set(re.findall(r'id:"(logo\.[\w.]+)"', src)))
    patched, signatures, count = patch_logo_components(src)
    if expected == 0 or count != expected:
        fail("found %d logo ids but rewrote %d components in %s" % (expected, count, echoes[0].name))
    echoes[0].write_text(JS_NOTICE + patched, encoding="utf-8")

    # step 2b: other inline brand marks, wherever they were compiled to
    token_files = []
    for p in sorted((web / "js").glob("*.js")):
        js = p.read_text(encoding="utf-8")
        if BRAND_TOKEN not in js:
            continue
        js, n = patch_brand_token_svgs(js)
        if n:
            if not js.startswith(JS_NOTICE):
                js = JS_NOTICE + js
            p.write_text(js, encoding="utf-8")
            token_files.append("%s:%d" % (p.name, n))

    # step 3
    shutil.copyfile(HERE / FOOTER_JS, web / FOOTER_JS)
    index = web / "index.html"
    html = index.read_text(encoding="utf-8")
    if FOOTER_TAG not in html:
        if html.count("</body>") != 1:
            fail("index.html has no single </body>")
        html = html.replace("</body>", "  " + FOOTER_TAG + "\n  </body>")
        html = html.replace("<!doctype html>\n", "<!doctype html>\n" + HTML_NOTICE, 1)
        index.write_text(html, encoding="utf-8")

    # step 4
    maps = list(web.rglob("*.map"))
    for p in maps:
        p.unlink()

    # Precompressed siblings of anything we touched must not serve stale bytes.
    touched = [web / r for r in REPLACE] + [echoes[0], index] + [web / "js" / t.split(":")[0] for t in token_files]
    for p in touched:
        if p.with_name(p.name + ".br").exists():
            fail("%s.br exists; brotli is not supported here" % p)
        gz = p.with_name(p.name + ".gz")
        if gz.exists():
            gz.write_bytes(gzip.compress(p.read_bytes(), 9))

    # gate 2: no upstream mark left in any text asset
    needles = ['id:"logo.', BRAND_TOKEN] + STATIC_SIGNATURES + signatures
    for p in web.rglob("*"):
        if p.is_file() and p.suffix.lower() in TEXT_EXT:
            text = p.read_text(encoding="utf-8", errors="ignore")
            hit = next((n for n in needles if n in text), None)
            if hit:
                fail("upstream mark %r still present in %s" % (hit, p.relative_to(web)))

    # gate 3: replaced bytes and wiring
    for rel, asset in REPLACE.items():
        if sha(web / rel) != sha(ASSETS / asset):
            fail("%s does not match assets/%s" % (rel, asset))
    if patched.count('"%s":"code-quality"' % MARK_ATTR) != expected:
        fail("logo component marker count mismatch")
    if FOOTER_TAG not in index.read_text(encoding="utf-8") or not (web / FOOTER_JS).is_file():
        fail("trademark footer script not wired")

    print("apply_brand: %s: replaced %d files, rewrote %d logo components and brand-token svgs in %s, "
          "removed %d source maps" % (web, len(REPLACE), count, token_files, len(maps)))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: apply_brand.py <webapp-dir>")
    main(pathlib.Path(sys.argv[1]))
