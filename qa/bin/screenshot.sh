#!/usr/bin/env bash
# Usage: screenshot.sh <name> <url> [width] [height]
# Captures a screenshot of a URL using Playwright
# Output: qa/results/<name>.png
set -euo pipefail

NAME="${1:?Usage: screenshot.sh <name> <url> [width] [height]}"
URL="${2:?Usage: screenshot.sh <name> <url> [width] [height]}"
WIDTH="${3:-1280}"
HEIGHT="${4:-720}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"
mkdir -p "$RESULTS_DIR"

OUTPUT="${RESULTS_DIR}/${NAME}.png"

# Generate and run a Playwright script
node -e "
const { chromium } = require('playwright');
const [url, output, w, h] = process.argv.slice(1);
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: parseInt(w), height: parseInt(h) } });
  await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
  await page.screenshot({ path: output, fullPage: false });
  await browser.close();
  console.log('Screenshot saved: ' + output);
})().catch(e => { console.error(e.message); process.exit(1); });
" "$URL" "$OUTPUT" "$WIDTH" "$HEIGHT" 2>&1

echo "$OUTPUT"
