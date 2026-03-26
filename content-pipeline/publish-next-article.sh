#!/usr/bin/env bash
# publish-next-article.sh
# Picks the next queued article, generates it via LLM, publishes to site, commits & pushes.
# Designed to run unattended from cron.
#
# Usage:
#   ./content-pipeline/publish-next-article.sh
#   ./content-pipeline/publish-next-article.sh --dry-run    (generate but don't push)
#   ./content-pipeline/publish-next-article.sh --id kalshi-review-uk-2026  (specific article)

set -euo pipefail

SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE_DIR="$SITE_DIR/content-pipeline"
QUEUE_FILE="$PIPELINE_DIR/article-queue.json"
LOG_FILE="$PIPELINE_DIR/publish.log"
DRY_RUN=false
SPECIFIC_ID=""

# ── Args ─────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --id) SPECIFIC_ID="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

log() { echo "[$(date -u '+%Y-%m-%d %H:%M UTC')] $*" | tee -a "$LOG_FILE"; }

log "=== publish-next-article.sh starting (dry_run=$DRY_RUN) ==="

# ── Pick next article ─────────────────────────────────────────────────────────
if [[ -n "$SPECIFIC_ID" ]]; then
  ARTICLE=$(python3 -c "
import json, sys
q = json.load(open('$QUEUE_FILE'))
a = next((x for x in q if x['id'] == '$SPECIFIC_ID'), None)
print(json.dumps(a) if a else '')
")
else
  ARTICLE=$(python3 -c "
import json
q = json.load(open('$QUEUE_FILE'))
a = next((x for x in q if x.get('status') == 'queued'), None)
print(json.dumps(a) if a else '')
")
fi

if [[ -z "$ARTICLE" || "$ARTICLE" == "null" ]]; then
  log "No queued articles remaining. Nothing to do."
  exit 0
fi

ARTICLE_ID=$(echo "$ARTICLE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['id'])")
ARTICLE_SLUG=$(echo "$ARTICLE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['slug'])")
ARTICLE_TITLE=$(echo "$ARTICLE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['title'])")
ARTICLE_DESC=$(echo "$ARTICLE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['description'])")
ARTICLE_KEYWORDS=$(echo "$ARTICLE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(d['keywords']))")
ARTICLE_AFFILIATES=$(echo "$ARTICLE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(d['affiliates']))")
ARTICLE_CATEGORY=$(echo "$ARTICLE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['category'])")

log "Selected article: $ARTICLE_ID — $ARTICLE_TITLE"

OUTPUT_FILE="$SITE_DIR/content/posts/${ARTICLE_SLUG}.md"

if [[ -f "$OUTPUT_FILE" ]]; then
  log "File already exists: $OUTPUT_FILE — skipping generation, marking published."
else
  log "Generating article via LLM..."

  TODAY=$(date -u '+%Y-%m-%d')
  AFFILIATE_SHORTCODES=$(echo "$ARTICLE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
affs = d.get('affiliates', [])
examples = []
for a in affs:
    examples.append(f'{{{{< affiliate link=\"{a}\" text=\"[relevant anchor text]\" >}}}}')
print('\n'.join(examples))
")

  PROMPT="You are a content writer for predictionprofits.co.uk — a UK-focused prediction markets and crypto passive income affiliate site with a sharp, knowledgeable, no-fluff voice. The site uses real first-person experience and ranks well for UK crypto/prediction market queries.

Write a complete, high-quality Hugo Markdown article for the following:

Title: $ARTICLE_TITLE
Slug: $ARTICLE_SLUG
Description: $ARTICLE_DESC
Target keywords: $ARTICLE_KEYWORDS
Category: $ARTICLE_CATEGORY
Date: $TODAY

The article must:
- Start with this exact frontmatter block (fill in the tags array with relevant tag strings):
---
title: \"$ARTICLE_TITLE\"
date: $TODAY
description: \"$ARTICLE_DESC\"
slug: \"$ARTICLE_SLUG\"
tags: [FILL_IN_5_TO_8_TAGS]
categories: [\"$ARTICLE_CATEGORY\"]
draft: false
---
- Be 1,200–2,000 words. Long enough to rank, tight enough to read.
- UK-focused. Use UK spellings, GBP amounts, reference UK-specific considerations (FCA, HMRC, Faster Payments etc.) where relevant.
- Include a clear H2 structure (at least 5 H2 sections).
- Sound like a knowledgeable practitioner, not a corporate writer.
- Use concrete numbers and examples where possible.
- Include 2–4 affiliate links using these Hugo shortcodes where contextually appropriate:
$AFFILIATE_SHORTCODES
  Replace [relevant anchor text] with natural anchor text that fits the sentence.
- End with a short FAQ section (3–5 questions, relevant to the article topic).
- Do NOT include any preamble, notes, or explanation — output ONLY the raw markdown starting with the frontmatter block.
- Do NOT hallucinate affiliate programmes that don't exist. Only use the shortcodes provided.
- Do NOT use markdown tables unless they genuinely add value.
- The tone should match the existing articles on the site: direct, slightly opinionated, practically useful."

  # Call the OpenRouter API (cheap fast model)
  OPENROUTER_KEY=$(python3 -c "
import json, os, pathlib
# Try reading from openclaw config
cfg_paths = [
  pathlib.Path.home() / '.openclaw/openclaw.json',
  pathlib.Path.home() / '.openclaw/config.json',
]
for p in cfg_paths:
    if p.exists():
        try:
            d = json.loads(p.read_text())
            # Walk nested keys looking for openrouter key
            def find_key(obj, depth=0):
                if depth > 6: return None
                if isinstance(obj, str) and obj.startswith('sk-or-'): return obj
                if isinstance(obj, dict):
                    for v in obj.values():
                        r = find_key(v, depth+1)
                        if r: return r
                return None
            k = find_key(d)
            if k: print(k); break
        except: pass
")

  if [[ -z "$OPENROUTER_KEY" ]]; then
    log "ERROR: Could not find OpenRouter API key in openclaw config."
    exit 1
  fi

  RESPONSE=$(python3 - "$OPENROUTER_KEY" "$PROMPT" <<'PYEOF'
import sys, json, urllib.request, urllib.error

api_key = sys.argv[1]
prompt  = sys.argv[2]

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
        content = data["choices"][0]["message"]["content"]
        print(content)
except urllib.error.HTTPError as e:
    print(f"HTTP ERROR {e.code}: {e.read().decode()}", file=sys.stderr)
    sys.exit(1)
PYEOF
  )

  if [[ -z "$RESPONSE" ]]; then
    log "ERROR: LLM returned empty response."
    exit 1
  fi

  # Strip any leading preamble before ---
  echo "$RESPONSE" | python3 -c "
import sys
content = sys.stdin.read()
# Find first occurrence of '---' and start from there
idx = content.find('---')
if idx >= 0:
    content = content[idx:]
print(content, end='')
" > "$OUTPUT_FILE"

  log "Article written to $OUTPUT_FILE"
fi

# ── Build site locally to check for errors ───────────────────────────────────
log "Building site to verify no Hugo errors..."
cd "$SITE_DIR"
if ! hugo --quiet 2>&1 | tee -a "$LOG_FILE"; then
  log "ERROR: Hugo build failed. Aborting push."
  rm -f "$OUTPUT_FILE"
  exit 1
fi
log "Hugo build OK."

# ── Update queue ──────────────────────────────────────────────────────────────
python3 -c "
import json
q = json.load(open('$QUEUE_FILE'))
for a in q:
    if a['id'] == '$ARTICLE_ID':
        a['status'] = 'published'
        import datetime
        a['published_date'] = datetime.date.today().isoformat()
json.dump(q, open('$QUEUE_FILE', 'w'), indent=2)
"
log "Queue updated: $ARTICLE_ID → published"

if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY RUN — not committing or pushing. File at: $OUTPUT_FILE"
  exit 0
fi

# ── Commit and push ───────────────────────────────────────────────────────────
cd "$SITE_DIR"
git add "content/posts/${ARTICLE_SLUG}.md" content-pipeline/article-queue.json
git commit -m "Add article: $ARTICLE_TITLE"
git push origin main
log "Pushed. Netlify will deploy automatically."
log "=== Done: $ARTICLE_ID ==="
