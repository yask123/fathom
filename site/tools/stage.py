#!/usr/bin/env python3
"""Puts a trace's stage geometry into the Tracer page, where its live trace is drawn from.

    site/tools/stage.py stage.json

Make stage.json with the app itself, off screen, from a pull request it has on disk:

    FATHOM_RENDER=/tmp/t.png FATHOM_RENDER_PR=owner/repo#12 FATHOM_STAGE_JSON=stage.json FATHOM_STAGE_WIDTH=1180 \
        build/Tracer.app/Contents/MacOS/Tracer
"""
import json, pathlib, re, sys

page = pathlib.Path(__file__).resolve().parent.parent / "tracer" / "index.html"
data = json.dumps(json.load(open(sys.argv[1])), separators=(",", ":"), ensure_ascii=False).replace("</", "<\\/")
html = page.read_text()
tag = re.compile(r'(<script id="stage-data" type="application/json">)(.*?)(</script>)', re.S)
assert tag.search(html), "no stage-data tag in the page"
page.write_text(tag.sub(lambda m: m.group(1) + data + m.group(3), html, count=1))
print(f"stage data: {len(data)} bytes into {page}")
