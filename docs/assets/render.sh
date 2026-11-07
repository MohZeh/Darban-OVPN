#!/usr/bin/env bash
# Renders the images from their HTML sources with a Chromium browser: docs/assets/render.sh [browser]
# hero.png and the diagrams are drawn at double size and have transparent corners; the social preview does not.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
browser=${1:-${BROWSER_BIN:-chromium}}
url_base=file://$(pwd -W 2>/dev/null || pwd)
shot() { # shot <source#fragment> <output> <width> <height> <scale>
    local out
    out=$(pwd -W 2>/dev/null || pwd)/$2
    "$browser" --headless=new --disable-gpu --hide-scrollbars --virtual-time-budget=6000 \
        --default-background-color=00000000 --force-device-scale-factor="$5" \
        --window-size="$3,$4" --screenshot="$out" "$url_base/$1" 2>/dev/null
}
shot 'hero.html#rounded' hero.png 1280 640 2
shot 'hero.html' social-preview.png 1280 640 1
shot 'how-it-works.html#dark' how-it-works-dark.png 1400 750 2
shot 'how-it-works.html#light' how-it-works-light.png 1400 750 2
