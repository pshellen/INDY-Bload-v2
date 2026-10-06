#!/usr/bin/env python3
"""Local preview server for the BLOAD Indy showings grid."""
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
from urllib.parse import parse_qs, urlparse
import argparse
import datetime
import json
import os
import sys

try:
    import pytz
except ImportError:
    pytz = None

PORT = 8765
HOST = "0.0.0.0"
ROOT = os.path.dirname(os.path.abspath(__file__))
GRAPHQL = "https://api-us.indy.systems/graphql"
UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"
)
DEFAULT_TZ = "US/Eastern"


def badge_is_3d(badge):
    title = (badge.get("title") or badge.get("displayName") or "").strip().lower()
    return title == "3d" or title.startswith("3d ") or " 3d" in title


def badge_is_sensory(badge):
    title = (badge.get("title") or badge.get("displayName") or "").strip().lower()
    return "sensory" in title


def badge_is_open_caption(badge):
    title = (badge.get("title") or badge.get("displayName") or "").strip().lower()
    return (
        "open caption" in title
        or title in ("oc", "open captions", "open captioning", "open captioned")
    )


def show_badge_flags(badges):
    badges = badges or []
    return {
        "threed": any(badge_is_3d(badge) for badge in badges),
        "sensory": any(badge_is_sensory(badge) for badge in badges),
        "open_caption": any(badge_is_open_caption(badge) for badge in badges),
    }


def is_showtime_badge_label(label):
    lower = label.lower()
    return (
        lower == "3d"
        or lower.startswith("3d ")
        or "sensory" in lower
        or "open caption" in lower
        or lower in ("oc", "open captions", "open captioning", "open captioned")
    )


def merge_showtimes(shows):
    merged = {}
    for show in shows:
        key = show["offset"]
        if key not in merged:
            merged[key] = dict(show)
            continue
        existing = merged[key]
        existing["threed"] = existing.get("threed") or show.get("threed")
        existing["sensory"] = existing.get("sensory") or show.get("sensory")
        existing["open_caption"] = existing.get("open_caption") or show.get("open_caption")
    return sorted(merged.values(), key=lambda s: s["offset"])


def showtime_parts(dt):
    hour, minute = dt.hour, dt.minute
    suffix = "am" if hour < 12 else "pm"
    display_hour = (hour - 1) % 12 + 1
    return {
        "hour": hour,
        "minute": minute,
        "offset": hour * 60 + minute,
        "string": "%d:%02d%s" % (display_hour, minute, suffix),
    }


def localize(dt, tz_name):
    if pytz is None:
        return dt.replace(tzinfo=None)
    dt = dt.replace(tzinfo=pytz.utc)
    return dt.astimezone(pytz.timezone(tz_name)).replace(tzinfo=None)


def parse_indy_showings(site, options):
    tz_name = options.get("timezone", DEFAULT_TZ)
    hide_past = bool(options.get("hide_past", False))
    movies = {}

    for show in site.get("todaysShowings", []):
        if hide_past and show.get("past"):
            continue

        movie = show["movie"]
        name = movie["name"]
        if name not in movies:
            movies[name] = {
                "name": name,
                "image": "".join(ch for ch in name.lower() if ch.isalnum()),
                "mpaa": (movie.get("rating") or "").strip(),
                "badges": [],
                "shows": [],
            }

        entry = movies[name]
        for badge in show.get("showingBadges") or []:
            label = (badge.get("displayName") or badge.get("title") or "").strip()
            if label and not is_showtime_badge_label(label) and label not in entry["badges"]:
                entry["badges"].append(label)

        dt = datetime.datetime.strptime(show["time"], "%Y-%m-%dT%H:%M:%SZ")
        dt = localize(dt, tz_name)
        parts = showtime_parts(dt)
        parts["past"] = bool(show.get("past"))
        parts["seats"] = 100
        parts["sold"] = 0
        parts.update(show_badge_flags(show.get("showingBadges")))
        entry["shows"].append(parts)

    sorted_movies = sorted(movies.values(), key=lambda m: m["name"].lower())
    for movie in sorted_movies:
        movie["shows"] = merge_showtimes(movie["shows"])

    return {
        "source": "indy",
        "site": site.get("name") or "",
        "movies": sorted_movies,
        "movies_per_page": int(options.get("movies_per_page", 4)),
        "page_interval": max(1, int(options.get("page_interval", 5))),
        "hide_poster": bool(options.get("hide_poster", True)),
        "display_badges": bool(options.get("display_badges", True)),
        "show_logo": bool(options.get("show_logo", False)),
    }


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/showings/"):
            site_id = parsed.path.split("/api/showings/", 1)[1].split("/", 1)[0]
            qs = parse_qs(parsed.query)
            options = {
                "timezone": qs.get("timezone", [DEFAULT_TZ])[0],
                "hide_past": qs.get("hide_past", ["0"])[0] in ("1", "true", "yes"),
                "movies_per_page": int(qs.get("movies_per_page", ["4"])[0]),
                "page_interval": int(qs.get("page_interval", ["5"])[0]),
                "hide_poster": qs.get("hide_poster", ["1"])[0] in ("1", "true", "yes"),
                "display_badges": qs.get("display_badges", ["1"])[0] in ("1", "true", "yes"),
                "show_logo": qs.get("show_logo", ["0"])[0] in ("1", "true", "yes"),
            }
            self.proxy_showings(site_id, options)
            return
        return super().do_GET()

    def proxy_showings(self, site_id, options):
        query = (
            "{ site(id: %s) { name todaysShowings { time current past "
            "showingBadges { id title displayName } "
            "movie { name rating ratingReason posterImage } } } }"
        ) % int(site_id)
        body = json.dumps({"query": query}).encode("utf-8")
        req = Request(
            GRAPHQL,
            data=body,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/graphql-response+json",
                "User-Agent": UA,
            },
            method="POST",
        )
        try:
            with urlopen(req, timeout=15) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            if payload.get("errors"):
                raise ValueError(payload["errors"][0].get("message", "GraphQL error"))
            site = payload.get("data", {}).get("site")
            if not site:
                raise ValueError("Indy returned no site data for id %s" % site_id)
            data = parse_indy_showings(site, options)
            encoded = json.dumps(data).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(encoded)
        except Exception as err:
            print("[preview] showings error for site %s: %s" % (site_id, err), file=sys.stderr)
            payload = json.dumps({"error": {"message": str(err)}}).encode("utf-8")
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="BLOAD Indy grid preview server")
    parser.add_argument("--host", default=HOST, help="bind address (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=PORT, help="port (default: 8765)")
    args = parser.parse_args()

    os.chdir(ROOT)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print("Serving %s" % ROOT)
    print("Preview: http://127.0.0.1:%d/preview.html" % args.port)
    print("API:     http://127.0.0.1:%d/api/showings/338" % args.port)
    print("Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
