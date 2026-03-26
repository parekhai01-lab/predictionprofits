#!/usr/bin/env python3
"""
generate-article.py
-------------------
Generates a single article for predictionprofits.co.uk using OpenRouter API.
Called by publish-next-article.sh.

Reads API key from (in priority order):
  1. OPENROUTER_API_KEY env var
  2. ~/.openclaw/openrouter.key (plain text file, one line)
  3. ~/.config/openrouter/key

Usage:
  python3 generate-article.py --id kalshi-review-uk-2026 --out /path/to/output.md
  python3 generate-article.py --json '{"id":...}' --out /path/to/output.md
"""

import argparse
import json
import os
import pathlib
import sys
import urllib.request
import urllib.error

GATEWAY_TOKEN = "84dfef1ba771c9a839e9064517d4c0c2e0c39b92de18e58f"
QUEUE_FILE = pathlib.Path(__file__).parent / "article-queue.json"


def get_api_key() -> str:
    # 1. Env var
    k = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if k and k.startswith("sk-or-"):
        return k

    # 2. Key file
    for p in [
        pathlib.Path.home() / ".openclaw/openrouter.key",
        pathlib.Path.home() / ".config/openrouter/key",
    ]:
        if p.exists():
            k = p.read_text().strip()
            if k.startswith("sk-or-"):
                return k

    return ""


def build_prompt(article: dict) -> str:
    today = __import__("datetime").date.today().isoformat()
    affs = article.get("affiliates", [])
    shortcodes = "\n".join(
        f'{{{{< affiliate link="{a}" text="[relevant anchor text]" >}}}}' for a in affs
    )
    keywords = ", ".join(article["keywords"])
    category = article["category"]
    title = article["title"]
    slug = article["slug"]
    description = article["description"]

    return f"""You are a content writer for predictionprofits.co.uk — a UK-focused prediction markets and crypto passive income affiliate site with a sharp, knowledgeable, no-fluff voice. The site uses real first-person experience and ranks well for UK crypto/prediction market queries.

Write a complete, high-quality Hugo Markdown article:

Title: {title}
Slug: {slug}
Description: {description}
Target keywords: {keywords}
Category: {category}
Date: {today}

Requirements:
- Start with this exact frontmatter (fill in 5–8 relevant tags as strings):
---
title: "{title}"
date: {today}
description: "{description}"
slug: "{slug}"
tags: [FILL_IN_TAGS]
categories: ["{category}"]
draft: false
---
- 1,200–2,000 words. Tight, readable.
- UK-focused: UK spellings, GBP amounts, reference FCA/HMRC/Faster Payments where relevant.
- At least 5 H2 sections with clear structure.
- Practitioner voice — concrete, slightly opinionated, not corporate.
- Use real numbers and examples wherever possible.
- Include 2–4 affiliate links using these shortcodes where contextually appropriate:
{shortcodes}
  Replace [relevant anchor text] with natural, contextual anchor text.
- End with a FAQ section (3–5 questions relevant to the article).
- Output ONLY the raw markdown starting with the frontmatter. No preamble, no notes.
- Only use the shortcodes provided. Do not invent affiliate programmes.
- Avoid markdown tables unless genuinely useful."""


def call_openrouter(api_key: str, prompt: str) -> str:
    payload = json.dumps({
        "model": "google/gemini-2.0-flash-lite-001",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 4096,
        "temperature": 0.7,
    }).encode()

    req = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://predictionprofits.co.uk",
            "X-Title": "PredictionProfits Content Pipeline",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
            return data["choices"][0]["message"]["content"]
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        raise RuntimeError(f"OpenRouter HTTP {e.code}: {body[:300]}")


def strip_preamble(content: str) -> str:
    idx = content.find("---")
    return content[idx:] if idx >= 0 else content


def main():
    parser = argparse.ArgumentParser()
    grp = parser.add_mutually_exclusive_group(required=True)
    grp.add_argument("--id", help="Article ID from queue")
    grp.add_argument("--json", help="Article JSON inline")
    parser.add_argument("--out", required=True, help="Output .md file path")
    args = parser.parse_args()

    if args.id:
        queue = json.loads(QUEUE_FILE.read_text())
        article = next((a for a in queue if a["id"] == args.id), None)
        if not article:
            print(f"ERROR: article id '{args.id}' not found in queue", file=sys.stderr)
            sys.exit(1)
    else:
        article = json.loads(args.json)

    api_key = get_api_key()
    if not api_key:
        print(
            "ERROR: No OpenRouter API key found.\n"
            "Set OPENROUTER_API_KEY env var or save key to ~/.openclaw/openrouter.key",
            file=sys.stderr,
        )
        sys.exit(2)

    prompt = build_prompt(article)
    print(f"Calling OpenRouter (gemini-2.0-flash-lite) for: {article['title']}", file=sys.stderr)
    content = call_openrouter(api_key, prompt)
    content = strip_preamble(content)

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(content)
    print(f"Written: {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
