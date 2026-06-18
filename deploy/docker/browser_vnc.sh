#!/usr/bin/env bash
# browser_vnc.sh - headed patchright Chromium served over noVNC.
#
# Runs a real (headed) patchright-patched Chromium inside a virtual X display
# and exposes it through noVNC so a remote machine can drive it from a web
# browser. Primary use: a one-time interactive login that populates the shared
# persistent profile the headless crawler then reuses.
set -euo pipefail

DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"
SCREEN_GEOMETRY="${SCREEN_GEOMETRY:-1440x900x24}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5900}"
PROFILE_DIR="${PROFILE_DIR:-/profiles/google-auth}"
START_URL="${START_URL:-https://accounts.google.com}"

mkdir -p "${PROFILE_DIR}"

cleanup() {
    pkill -P $$ 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 1) Virtual display
Xvfb "${DISPLAY}" -screen 0 "${SCREEN_GEOMETRY}" -nolisten tcp &
for _ in $(seq 1 50); do
    [ -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ] && break
    sleep 0.1
done

# 2) Minimal window manager
fluxbox >/dev/null 2>&1 &

# 3) VNC server bound to loopback (noVNC proxies it; the port is not published)
x11vnc -display "${DISPLAY}" -nopw -forever -shared -rfbport "${VNC_PORT}" \
    -localhost -quiet >/dev/null 2>&1 &

# 4) noVNC web frontend
websockify --web=/usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" \
    >/dev/null 2>&1 &

echo "browser-vnc: noVNC on :${NOVNC_PORT} -> open http://<host>:${NOVNC_PORT}/vnc.html"
echo "browser-vnc: using profile ${PROFILE_DIR}"

# 5) Headed patchright Chromium on the persistent profile. Launching via
# patchright (not the system browser) keeps the profile format identical to
# what the headless crawler launches, so the persisted session is reused.
exec python - "$PROFILE_DIR" "$START_URL" <<'PY'
import sys, asyncio
from patchright.async_api import async_playwright

profile_dir, start_url = sys.argv[1], sys.argv[2]

async def main():
    async with async_playwright() as p:
        ctx = await p.chromium.launch_persistent_context(
            profile_dir,
            headless=False,
            args=["--no-sandbox", "--disable-dev-shm-usage", "--start-maximized"],
            no_viewport=True,
        )
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        await page.goto(start_url)
        # Keep the context alive until the container is stopped so the operator
        # can interact; closing it would tear down the browser.
        while True:
            await asyncio.sleep(3600)

asyncio.run(main())
PY
