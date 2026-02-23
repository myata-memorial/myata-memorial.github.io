#!/usr/bin/env python3
"""
Translate _index.ru.md into English (_index.en.md) and Georgian (_index.ka.md)
using the OpenAI API.  No external dependencies -- uses only stdlib (urllib).

Usage:
    OPENAI_API_KEY=sk-... python3 scripts/translate.py [--file content/_index.ru.md]
    OPENAI_API_KEY=sk-... python3 scripts/translate.py --dry-run   # split only, no API

Env:
    OPENAI_API_KEY  -- required (unless --dry-run)
    OPENAI_MODEL    -- optional, default: gpt-4o-mini
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
API_KEY = os.environ.get("OPENAI_API_KEY", "")
API_URL = "https://api.openai.com/v1/chat/completions"
MODEL = os.environ.get("OPENAI_MODEL", "gpt-4o-mini")

# ---------------------------------------------------------------------------
# Prompt template
# ---------------------------------------------------------------------------
SYSTEM_PROMPT = """\
You are a professional translator. Translate the following Markdown text from \
Russian to {lang_name}.

Rules:
- Preserve ALL Markdown formatting exactly (headings, bold, italic, links, etc.).
- Preserve ALL Hugo shortcodes ({{{{< ... >}}}}) exactly as they are -- do NOT \
translate anything inside shortcodes.
- Preserve ALL emoji characters exactly.
- Preserve image/audio/video paths exactly -- do NOT translate file paths.
- Inside gallery shortcodes the pattern is "path|caption" -- translate ONLY the \
caption part after the pipe (|), keep the path unchanged.
- Keep proper names (Мята/Myata, Саша/Sasha, Вита/Vita, etc.) transliterated \
appropriately for {lang_name}. "Мята" should be "Myata" in English and \
"მიატა" in Georgian.
- Do NOT add any explanations -- return ONLY the translated Markdown.\
"""


# ---------------------------------------------------------------------------
# OpenAI API call (stdlib only)
# ---------------------------------------------------------------------------
def call_openai(text: str, lang_name: str, retries: int = 3) -> str:
    """Send a translation request and return the translated text."""
    payload = json.dumps({
        "model": MODEL,
        "temperature": 0.3,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT.format(lang_name=lang_name)},
            {"role": "user", "content": text},
        ],
    }).encode("utf-8")

    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    }

    for attempt in range(1, retries + 1):
        req = urllib.request.Request(API_URL, data=payload, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                body = json.loads(resp.read().decode("utf-8"))
                return body["choices"][0]["message"]["content"]
        except urllib.error.HTTPError as exc:
            if exc.code == 429:
                wait = int(exc.headers.get("Retry-After", 5))
                print(f"  rate-limited, waiting {wait}s ...")
                time.sleep(wait)
                continue
            print(f"  attempt {attempt}/{retries} HTTP {exc.code}: {exc.reason}")
        except Exception as exc:
            print(f"  attempt {attempt}/{retries} failed: {exc}")
        if attempt < retries:
            time.sleep(2 * attempt)

    sys.exit("ERROR: OpenAI API call failed after retries.")


# ---------------------------------------------------------------------------
# Frontmatter helpers
# ---------------------------------------------------------------------------
FM_RE = re.compile(r"^(\+\+\+|---)\s*\n(.*?)\n\1\s*\n", re.DOTALL)


def extract_frontmatter(text: str):
    """Return (frontmatter_with_delimiters, body_after_frontmatter)."""
    m = FM_RE.match(text)
    if m:
        return m.group(0), text[m.end():]
    return "", text


def translate_frontmatter(fm: str, lang_name: str) -> str:
    """Translate only the title value inside the frontmatter."""
    if not fm.strip():
        return fm

    def _replace(match):
        original = match.group(1)
        translated = call_openai(original, lang_name).strip().strip("'\"")
        return f"title = '{translated}'"

    return re.sub(r"title\s*=\s*'([^']*)'", _replace, fm)


# ---------------------------------------------------------------------------
# Chunk splitter
# ---------------------------------------------------------------------------
HEADING_RE = re.compile(r"^(#{1,6})\s", re.MULTILINE)


def split_into_chunks(body: str) -> list:
    """Split markdown body on heading lines.
    Each chunk = {"heading": "...", "text": "..."}"""
    chunks = []
    positions = [m.start() for m in HEADING_RE.finditer(body)]

    if not positions:
        return [{"heading": "", "text": body}]

    # Text before the first heading
    if positions[0] > 0:
        pre = body[:positions[0]]
        if pre.strip():
            chunks.append({"heading": "(preamble)", "text": pre})

    for i, pos in enumerate(positions):
        end = positions[i + 1] if i + 1 < len(positions) else len(body)
        chunk_text = body[pos:end]
        heading_line = chunk_text.split("\n", 1)[0].strip()
        chunks.append({"heading": heading_line, "text": chunk_text})

    return chunks


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Translate _index.ru.md via OpenAI")
    parser.add_argument(
        "--file", default="content/_index.ru.md",
        help="Source Russian markdown (default: content/_index.ru.md)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Only split into chunks and dump _chunks.json, no API calls",
    )
    args = parser.parse_args()

    src = Path(args.file)
    if not src.exists():
        sys.exit(f"ERROR: file not found: {src}")
    if not args.dry_run and not API_KEY:
        sys.exit("ERROR: set OPENAI_API_KEY environment variable")

    raw = src.read_text(encoding="utf-8")
    frontmatter, body = extract_frontmatter(raw)
    chunks = split_into_chunks(body)

    print(f"Loaded {src}  ({len(raw)} chars, {len(raw.splitlines())} lines)")
    print(f"Frontmatter: {len(frontmatter)} chars")
    print(f"Chunks: {len(chunks)}")
    print()

    # --- debug JSON ----------------------------------------------------------
    out_dir = src.parent
    debug_path = out_dir / "_chunks.json"
    debug_data = [
        {
            "index": i,
            "heading": c["heading"],
            "length": len(c["text"]),
            "preview": c["text"][:120].replace("\n", "\\n"),
        }
        for i, c in enumerate(chunks)
    ]
    debug_path.write_text(
        json.dumps(debug_data, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"Wrote {debug_path}")

    if args.dry_run:
        print("\n--dry-run: stopping before API calls.")
        for i, c in enumerate(chunks):
            print(f"  chunk {i}: {c['heading'][:70]}  ({len(c['text'])} chars)")
        return

    # --- translate for each target language ----------------------------------
    targets = [
        {"lang_name": "English",  "lang_code": "en"},
        {"lang_name": "Georgian", "lang_code": "ka"},
    ]

    for target in targets:
        lang_name = target["lang_name"]
        lang_code = target["lang_code"]
        out_path = out_dir / f"_index.{lang_code}.md"

        print(f"\n{'=' * 60}")
        print(f" Translating to {lang_name} ({lang_code})")
        print(f"{'=' * 60}")

        # Translate the title in frontmatter
        print("  [title] translating frontmatter title ...")
        translated_fm = translate_frontmatter(frontmatter, lang_name)

        # Translate each chunk
        translated_chunks = []
        for i, chunk in enumerate(chunks):
            text = chunk["text"]
            heading = chunk["heading"]

            if not text.strip():
                translated_chunks.append(text)
                continue

            label = heading[:60] if heading else "(text)"
            print(f"  [{i + 1}/{len(chunks)}] {label}  ({len(text)} chars)")
            translated = call_openai(text, lang_name)
            translated_chunks.append(translated)

            # tiny pause to be gentle with rate limits
            time.sleep(0.25)

        full = translated_fm + "".join(translated_chunks)
        full = full.rstrip("\n") + "\n"

        out_path.write_text(full, encoding="utf-8")
        print(f"\n  -> Wrote {out_path}  ({len(full)} chars)")

    print("\nDone!")


if __name__ == "__main__":
    main()
