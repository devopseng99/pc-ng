#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Ingest an existing website to extract business data for template population.
# Scrapes key pages and extracts structured data (name, services, pricing,
# about, contact, testimonials) into a JSON file.
#
# Usage:
#   ./ingest-website.sh --url https://example.com --output manifests/custom/example.json
#   ./ingest-website.sh --url https://example.com --id 201 --manifest manifests/use-cases.json
#
# The output JSON can be passed to generate-prompt.sh via --source-data
# to replace template placeholders with real business content.
# ============================================================================

URL="" OUTPUT="" TARGET_ID="" MANIFEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)      URL="$2"; shift 2 ;;
    --output)   OUTPUT="$2"; shift 2 ;;
    --id)       TARGET_ID="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ -z "$URL" ]] && { echo "Error: --url required"; exit 1; }
[[ -z "$OUTPUT" ]] && OUTPUT="/tmp/ingested-$(date +%s).json"

echo "Ingesting: $URL"

# Normalize URL
BASE_URL="${URL%/}"

# Scrape pages and extract text content
python3 << 'PYEOF'
import json
import subprocess
import re
import sys

base_url = sys.argv[1] if len(sys.argv) > 1 else ""
output_path = sys.argv[2] if len(sys.argv) > 2 else "/tmp/ingested.json"

def fetch(url, timeout=15):
    """Fetch URL content via curl"""
    try:
        result = subprocess.run(
            ["curl", "-sL", "--max-time", str(timeout), "-H", "User-Agent: Mozilla/5.0", url],
            capture_output=True, text=True, timeout=timeout+5
        )
        return result.stdout
    except:
        return ""

def strip_html(html):
    """Extract visible text from HTML"""
    # Remove script/style
    html = re.sub(r'<(script|style)[^>]*>.*?</\1>', '', html, flags=re.DOTALL|re.IGNORECASE)
    # Remove HTML tags
    text = re.sub(r'<[^>]+>', ' ', html)
    # Normalize whitespace
    text = re.sub(r'\s+', ' ', text).strip()
    return text

def extract_meta(html):
    """Extract meta tags"""
    meta = {}
    # Title
    m = re.search(r'<title[^>]*>(.*?)</title>', html, re.IGNORECASE|re.DOTALL)
    if m: meta['title'] = m.group(1).strip()
    # Meta description
    m = re.search(r'<meta[^>]*name=["\']description["\'][^>]*content=["\'](.*?)["\']', html, re.IGNORECASE)
    if m: meta['description'] = m.group(1).strip()
    # OG tags
    for tag in ['og:title', 'og:description', 'og:image']:
        m = re.search(rf'<meta[^>]*property=["\']' + tag + r'["\'][^>]*content=["\'](.*?)["\']', html, re.IGNORECASE)
        if m: meta[tag.replace('og:', 'og_')] = m.group(1).strip()
    return meta

def extract_links(html, base):
    """Extract internal page links"""
    links = set()
    for m in re.finditer(r'href=["\'](/?[a-zA-Z0-9/_-]+)["\']', html):
        path = m.group(1)
        if path.startswith('/'):
            links.add(base + path)
        elif path.startswith(base):
            links.add(path)
    return list(links)[:20]  # Cap at 20

def extract_emails(text):
    return list(set(re.findall(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', text)))

def extract_phones(text):
    return list(set(re.findall(r'[\(]?\d{3}[\)]?[-.\s]?\d{3}[-.\s]?\d{4}', text)))

def extract_prices(text):
    return list(set(re.findall(r'\$[\d,]+(?:\.\d{2})?', text)))[:20]

# --- Main scraping ---
print(f"Fetching {base_url}...")
homepage_html = fetch(base_url)
if not homepage_html:
    print("Failed to fetch homepage")
    sys.exit(1)

data = {
    "source_url": base_url,
    "meta": extract_meta(homepage_html),
    "pages": {},
    "contact": {
        "emails": extract_emails(strip_html(homepage_html)),
        "phones": extract_phones(strip_html(homepage_html)),
    },
    "pricing": extract_prices(strip_html(homepage_html)),
}

# Scrape homepage
data["pages"]["home"] = {
    "url": base_url,
    "text": strip_html(homepage_html)[:3000]
}

# Find and scrape key pages
internal_links = extract_links(homepage_html, base_url)
key_pages = {
    "about": ["about", "about-us", "our-story"],
    "services": ["services", "products", "menu", "what-we-do", "offerings"],
    "pricing": ["pricing", "plans", "packages", "membership"],
    "contact": ["contact", "contact-us", "get-in-touch", "location"],
    "gallery": ["gallery", "portfolio", "work", "projects", "photos"],
    "faq": ["faq", "frequently-asked", "help"],
    "blog": ["blog", "news", "articles", "resources"],
    "testimonials": ["testimonials", "reviews", "clients"],
}

for page_type, slugs in key_pages.items():
    for link in internal_links:
        path = link.rstrip('/').split('/')[-1].lower()
        if any(s in path for s in slugs):
            print(f"  Fetching {page_type}: {link}")
            html = fetch(link)
            if html:
                text = strip_html(html)
                data["pages"][page_type] = {
                    "url": link,
                    "text": text[:3000]
                }
                # Extract contact info from contact page
                if page_type == "contact":
                    data["contact"]["emails"] += extract_emails(text)
                    data["contact"]["phones"] += extract_phones(text)
                if page_type == "pricing":
                    data["pricing"] += extract_prices(text)
            break

# Deduplicate
data["contact"]["emails"] = list(set(data["contact"]["emails"]))
data["contact"]["phones"] = list(set(data["contact"]["phones"]))
data["pricing"] = list(set(data["pricing"]))

# Write output
with open(output_path, 'w') as f:
    json.dump(data, f, indent=2)

print(f"\nIngested {len(data['pages'])} pages → {output_path}")
print(f"  Emails: {data['contact']['emails']}")
print(f"  Phones: {data['contact']['phones']}")
print(f"  Prices found: {len(data['pricing'])}")

PYEOF

echo ""
echo "Source data saved to: $OUTPUT"
echo "Use with: ./scripts/generate-prompt.sh --source-data $OUTPUT ..."
