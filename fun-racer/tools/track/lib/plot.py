"""Top-down check plot of a built track: centreline coloured by elevation, turn numbers,
finish / start lines and sector boundaries.

    python3 tools/track/lib/plot.py <track folder> [output.png|.svg]

Uses matplotlib when it is installed; otherwise writes an SVG by hand (same content).
North is up. Elevation uses one hue from light (low) to dark (high).
"""
import json
import math
import os
import sys

INK = "#1f2430"
MUTED = "#6b7280"
SURFACE = "#ffffff"
RAMP = ["#d6e6f5", "#9cc3e6", "#5b9bd5", "#2f6fb0", "#174a85", "#0b2c57"]   # low -> high


def _load(track_dir):
    with open(os.path.join(track_dir, "track.json"), encoding="utf-8") as f:
        return json.load(f)


def _ramp(t):
    t = min(1.0, max(0.0, t)) * (len(RAMP) - 1)
    i = min(int(t), len(RAMP) - 2)
    a, b = RAMP[i], RAMP[i + 1]
    f = t - i
    return "#" + "".join(f"{round(int(a[k:k + 2], 16) + (int(b[k:k + 2], 16) - int(a[k:k + 2], 16)) * f):02x}"
                         for k in (1, 3, 5))


def _geometry(track):
    """Plot coordinates (x east, y north), heights, and label anchors."""
    pts = track["points"]
    n = len(pts)
    step = track["step"]
    xs = [p["p"][0] for p in pts]
    ys = [-p["p"][2] for p in pts]
    hs = [p["p"][1] for p in pts]

    def at(s):
        k = int(round(s / step)) % n
        a, b = (k - 2) % n, (k + 2) % n
        tx, ty = xs[b] - xs[a], ys[b] - ys[a]
        l = math.hypot(tx, ty) or 1.0
        return k, (xs[k], ys[k]), (tx / l, ty / l)

    labels = []
    for t in track["turns"]:
        k, (x, y), (tx, ty) = at(t["s_apex"])
        # Label on the outside of the corner: left turn -> to the right of travel.
        side = -1.0 if t["direction"] == "left" else 1.0
        nx, ny = -ty * side, tx * side
        labels.append((t["id"][1:], x, y, x + nx * 55.0, y + ny * 55.0))
    marks = [("finish", at(0.0))]
    if abs(track.get("start_s", 0.0)) > 1.0:
        marks.append(("start", at(track["start_s"])))
    for i, s in enumerate(track.get("sectors", [])[1:]):
        marks.append((f"S{i + 2}", at(s)))
    return xs, ys, hs, labels, marks


def _title(track):
    return (f"{track['name']}  -  {track['length']:.0f} m, {len(track['turns'])} turns, "
            f"{track['direction']}, elevation range {track['elevation_range']:.1f} m")


def _render_matplotlib(track, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.patheffects as pe
    import matplotlib.pyplot as plt
    from matplotlib.collections import LineCollection
    from matplotlib.colors import LinearSegmentedColormap

    xs, ys, hs, labels, marks = _geometry(track)
    n = len(xs)
    segs = [[(xs[i], ys[i]), (xs[(i + 1) % n], ys[(i + 1) % n])] for i in range(n)]
    cmap = LinearSegmentedColormap.from_list("elevation", RAMP)
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    fig, ax = plt.subplots(figsize=(11, max(5.0, min(11.0, 11 * (h + 300) / (w + 300)))), dpi=110)
    fig.patch.set_facecolor(SURFACE)
    ax.add_collection(LineCollection(segs, colors="#c9ced6", linewidths=7.5, capstyle="round"))
    lc = LineCollection(segs, cmap=cmap, linewidths=4.5, capstyle="round")
    lc.set_array([0.5 * (hs[i] + hs[(i + 1) % n]) for i in range(n)])
    ax.add_collection(lc)
    halo = [pe.withStroke(linewidth=3, foreground=SURFACE)]
    for text, x, y, lx, ly in labels:
        ax.plot([x, lx], [y, ly], color=MUTED, linewidth=0.8, zorder=3)
        ax.text(lx, ly, text, ha="center", va="center", fontsize=11, fontweight="bold", color=INK,
                path_effects=halo, zorder=4)
    for name, (k, (x, y), (tx, ty)) in marks:
        nx, ny = -ty, tx
        main = name in ("finish", "start")
        ax.plot([x - nx * 28, x + nx * 28], [y - ny * 28, y + ny * 28], color=INK,
                linewidth=2.2 if main else 1.2, linestyle="-" if main else (0, (3, 2)), zorder=5)
        ax.text(x - nx * 75, y - ny * 75, name, ha="center", va="center", fontsize=9, color=MUTED,
                path_effects=halo, zorder=4)
    # Direction of travel just after the finish line.
    k, (x, y), (tx, ty) = marks[0][1]
    ax.annotate("", xy=(x + tx * 150 + -ty * 45, y + ty * 150 + tx * 45),
                xytext=(x + tx * 40 + -ty * 45, y + ty * 40 + tx * 45),
                arrowprops={"arrowstyle": "-|>", "color": INK, "lw": 1.4}, zorder=5)
    ax.set_aspect("equal")
    pad = 140
    ax.set_xlim(min(xs) - pad, max(xs) + pad)
    ax.set_ylim(min(ys) - pad, max(ys) + pad)
    ax.set_xlabel("east of the finish line (m)", color=MUTED)
    ax.set_ylabel("north of the finish line (m)", color=MUTED)
    ax.tick_params(colors=MUTED, labelsize=8)
    ax.grid(True, color="#eceef2", linewidth=0.6)
    ax.set_axisbelow(True)
    for sp in ax.spines.values():
        sp.set_color("#d7dbe2")
    cb = fig.colorbar(lc, ax=ax, shrink=0.7, pad=0.02)
    cb.set_label("height above the finish line (m)", color=MUTED)
    cb.ax.tick_params(colors=MUTED, labelsize=8)
    cb.outline.set_edgecolor("#d7dbe2")
    ax.set_title(_title(track), color=INK, fontsize=11, loc="left")
    fig.text(0.01, 0.01, track.get("attribution", ""), fontsize=6.5, color=MUTED)
    fig.tight_layout(rect=(0, 0.02, 1, 1))
    fig.savefig(path)
    plt.close(fig)


def _render_svg(track, path):
    xs, ys, hs, labels, marks = _geometry(track)
    n = len(xs)
    pad = 160.0
    x0, x1, y0, y1 = min(xs) - pad, max(xs) + pad, min(ys) - pad, max(ys) + pad
    scale = 1000.0 / (x1 - x0)
    width, height = 1000.0, (y1 - y0) * scale + 60.0

    def P(x, y):
        return f"{(x - x0) * scale:.1f},{(y1 - y) * scale + 40.0:.1f}"

    lo, hi = min(hs), max(hs)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width:.0f} {height:.0f}" '
           f'font-family="sans-serif">', f'<rect width="100%" height="100%" fill="{SURFACE}"/>',
           f'<text x="12" y="24" font-size="15" fill="{INK}">{_title(track)}</text>']
    loop = " ".join(P(xs[i], ys[i]) for i in range(n))
    out.append(f'<polygon points="{loop}" fill="none" stroke="#c9ced6" stroke-width="9" stroke-linejoin="round"/>')
    for i in range(0, n, 2):
        j = (i + 2) % n
        m = (i + 1) % n
        c = _ramp((hs[m] - lo) / max(hi - lo, 1e-6))
        out.append(f'<polyline points="{P(xs[i], ys[i])} {P(xs[m], ys[m])} {P(xs[j], ys[j])}" fill="none" '
                   f'stroke="{c}" stroke-width="5" stroke-linecap="round"/>')
    for name, (k, (x, y), (tx, ty)) in marks:
        nx, ny = -ty, tx
        dash = "" if name in ("finish", "start") else ' stroke-dasharray="5 4"'
        a, b = P(x - nx * 28, y - ny * 28).split(","), P(x + nx * 28, y + ny * 28).split(",")
        out.append(f'<line x1="{a[0]}" y1="{a[1]}" x2="{b[0]}" y2="{b[1]}" stroke="{INK}" stroke-width="2.5"{dash}/>')
        t = P(x - nx * 75, y - ny * 75).split(",")
        out.append(f'<text x="{t[0]}" y="{t[1]}" font-size="12" fill="{MUTED}" text-anchor="middle">{name}</text>')
    for text, x, y, lx, ly in labels:
        a, b = P(x, y).split(","), P(lx, ly).split(",")
        out.append(f'<line x1="{a[0]}" y1="{a[1]}" x2="{b[0]}" y2="{b[1]}" stroke="{MUTED}" stroke-width="1"/>')
        out.append(f'<text x="{b[0]}" y="{b[1]}" font-size="15" font-weight="bold" fill="{INK}" stroke="{SURFACE}" '
                   f'stroke-width="3" paint-order="stroke" text-anchor="middle" dominant-baseline="middle">{text}</text>')
    for i in range(6):
        out.append(f'<rect x="{width - 190 + i * 26:.0f}" y="{height - 22:.0f}" width="26" height="10" fill="{RAMP[i]}"/>')
    out.append(f'<text x="{width - 196:.0f}" y="{height - 13:.0f}" font-size="11" fill="{MUTED}" text-anchor="end">'
               f'height above the finish line: {lo:.0f} m</text>')
    out.append(f'<text x="{width - 30:.0f}" y="{height - 13:.0f}" font-size="11" fill="{MUTED}">{hi:.0f} m</text>')
    out.append("</svg>")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out))


def render(track_dir, path=None):
    """Writes the plot and returns its path (a .svg when matplotlib is not available)."""
    track = _load(track_dir)
    path = path or os.path.join(track_dir, "plot.png")
    if not path.lower().endswith(".svg"):
        try:
            _render_matplotlib(track, path)
            return path
        except ImportError:
            path = os.path.splitext(path)[0] + ".svg"
    _render_svg(track, path)
    return path


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    print(render(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None))
