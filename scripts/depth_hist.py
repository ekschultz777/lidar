"""Shared Float32 depth TIFF I/O and bar-histogram drawing."""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np


def load_float_tiff(path: Path) -> np.ndarray:
    try:
        import tifffile
    except ImportError:
        tifffile = None

    if tifffile is not None:
        data = np.asarray(tifffile.imread(path))
    else:
        try:
            from PIL import Image
        except ImportError as exc:
            raise SystemExit(
                "Need Pillow to read TIFFs.\n"
                "  pip install numpy pillow"
            ) from exc
        with Image.open(path) as image:
            data = np.asarray(image)

    if data.ndim == 3 and data.shape[-1] == 1:
        data = data[..., 0]
    if data.ndim != 2:
        raise SystemExit(
            f"{path} has shape {data.shape}; expected a 2D grayscale TIFF."
        )
    if not np.issubdtype(data.dtype, np.floating):
        raise SystemExit(
            f"{path} is {data.dtype}, not floating-point. "
            "This script expects the Float32 depth TIFFs from the lidar app."
        )
    return data.astype(np.float32, copy=False)


def save_float_tiff(path: Path, data: np.ndarray) -> None:
    pixels = np.ascontiguousarray(data, dtype=np.float32)
    try:
        import tifffile
    except ImportError:
        tifffile = None

    if tifffile is not None:
        tifffile.imwrite(path, pixels, photometric="minisblack")
        return

    try:
        from PIL import Image
    except ImportError as exc:
        raise SystemExit(
            "Need Pillow to write TIFFs.\n"
            "  pip install numpy pillow"
        ) from exc
    Image.fromarray(pixels).save(path, format="TIFF")


def auto_bin_count(vmin: float, vmax: float) -> int:
    span = max(vmax - vmin, 1e-9)
    return min(max(int(round(span / 0.0002)), 400), 2500)


def _hex_rgb(color: str) -> tuple[int, int, int]:
    value = color.lstrip("#")
    return (int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16))


def _load_font(size: int):
    from PIL import ImageFont

    candidates = (
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
        "/System/Library/Fonts/SFNSText.ttf",
    )
    for font_path in candidates:
        if Path(font_path).is_file():
            try:
                return ImageFont.truetype(font_path, size=size)
            except OSError:
                continue
    return ImageFont.load_default()


def _nice_step(raw: float) -> float:
    if raw <= 0:
        return 1.0
    mag = 10 ** math.floor(math.log10(raw))
    n = raw / mag
    if n <= 1:
        return mag
    if n <= 2:
        return 2 * mag
    if n <= 5:
        return 5 * mag
    return 10 * mag


def _format_y_tick(value: float, step: float, y_style: str) -> str:
    if y_style == "count":
        return f"{int(round(value)):,}"
    if step >= 1:
        return f"{value:.0f}"
    decimals = max(1, min(6, -math.floor(math.log10(step))))
    return f"{value:.{decimals}f}"


def _format_delta_value(value: float) -> str:
    mag = abs(value)
    sign = "−" if value < 0 else ""
    if mag >= 1:
        return f"{sign}{mag:.3f} m"
    if mag >= 0.01:
        return f"{sign}{mag:.4f} m"
    return f"{sign}{mag * 1000:.3f} mm"


def _format_peak(peak: float, depth: float, y_style: str, label: str = "peak") -> str:
    if y_style == "count":
        return f"{label} {int(round(peak)):,} at {depth:.4f} m"
    return f"{label} {_format_delta_value(peak)} at {depth:.4f} m"


def write_bar_histogram(
    path: Path,
    edges: np.ndarray,
    heights: np.ndarray,
    *,
    title: str,
    subtitle: str,
    xlabel: str,
    ylabel: str,
    y_style: str = "count",
) -> tuple[float, float, float]:
    try:
        from PIL import Image, ImageDraw
    except ImportError as exc:
        raise SystemExit(
            "Need Pillow to write the histogram PNG.\n"
            "  pip install numpy pillow"
        ) from exc

    heights = np.asarray(heights, dtype=np.float64)
    vmin = float(edges[0])
    vmax = float(edges[-1])
    span = max(vmax - vmin, 1e-9)
    bins = len(heights)
    actual_max = float(heights.max(initial=0)) if heights.size else 0.0
    actual_min = float(heights.min(initial=0)) if heights.size else 0.0
    y_hi = max(actual_max, 0.0)
    y_lo = min(actual_min, 0.0)
    extent = max(abs(y_hi), abs(y_lo))
    if extent <= 0:
        y_step = 1.0 if y_style == "count" else 0.001
        ymax = y_step
        ymin = 0.0 if y_style == "count" else -y_step
    else:
        y_step = _nice_step(extent / 8)
        ymax = max(0.0, math.ceil(y_hi / y_step - 1e-12) * y_step)
        ymin = min(0.0, math.floor(y_lo / y_step + 1e-12) * y_step)
    if ymax <= ymin:
        ymax = ymin + y_step
    y_range = ymax - ymin
    max_i = int(heights.argmax()) if heights.size else 0
    min_i = int(heights.argmin()) if heights.size else 0
    max_depth = float((edges[max_i] + edges[max_i + 1]) / 2) if heights.size else vmin
    min_depth = float((edges[min_i] + edges[min_i + 1]) / 2) if heights.size else vmin
    peak = actual_max if abs(actual_max) >= abs(actual_min) else actual_min
    peak_depth = max_depth if abs(actual_max) >= abs(actual_min) else min_depth
    bin_mm = span / bins * 1000

    px_per_bar = 4 if bins <= 800 else (3 if bins <= 1500 else 2)
    left, right, top, bottom = 140, 48, 100, 96
    plot_w = max(2000, bins * px_per_bar)
    plot_h = 820
    width = left + plot_w + right
    height = top + plot_h + bottom

    ink = _hex_rgb("#1a1a1a")
    muted = _hex_rgb("#5c6570")
    grid = _hex_rgb("#e6e9ed")
    pos_bar = _hex_rgb("#2f6fed")
    pos_top = _hex_rgb("#1d4fbf")
    neg_bar = _hex_rgb("#c44b4b")
    neg_top = _hex_rgb("#9b2c2c")
    zero_line = _hex_rgb("#5c6570")

    image = Image.new("RGB", (width, height), (255, 255, 255))
    draw = ImageDraw.Draw(image)
    font = _load_font(22)
    font_small = _load_font(18)
    font_title = _load_font(28)
    font_tiny = _load_font(14)

    def x_of(value: float) -> int:
        return left + int(round((value - vmin) / span * plot_w))

    def y_of(value: float) -> int:
        return top + plot_h - int(round((value - ymin) / y_range * plot_h))

    draw.rectangle([left, top, left + plot_w, top + plot_h], fill=(252, 253, 254))

    tick = ymin
    while tick <= ymax + y_step * 0.01:
        y = y_of(tick)
        draw.line([(left, y), (left + plot_w, y)], fill=grid, width=1)
        label = _format_y_tick(tick, y_step, y_style)
        bbox = draw.textbbox((0, 0), label, font=font_small)
        draw.text(
            (left - 12 - (bbox[2] - bbox[0]), y - (bbox[3] - bbox[1]) / 2),
            label,
            fill=muted,
            font=font_small,
        )
        tick += y_step

    y_zero = y_of(0.0)
    draw.line([(left, y_zero), (left + plot_w, y_zero)], fill=zero_line, width=2)

    bar_gap = 1 if px_per_bar >= 3 else 0
    label_counts = px_per_bar >= 14
    for i, n in enumerate(heights):
        bx0 = x_of(edges[i])
        bx1 = x_of(edges[i + 1]) - bar_gap
        if bx1 <= bx0:
            bx1 = bx0 + 1
        if n == 0:
            continue
        y1 = y_of(float(n))
        top_y, bot_y = (y1, y_zero) if n > 0 else (y_zero, y1)
        if bot_y <= top_y:
            bot_y = top_y + 1
        fill = pos_bar if n > 0 else neg_bar
        draw.rectangle([bx0, top_y, bx1, bot_y], fill=fill)
        if label_counts:
            label = _format_y_tick(float(n), y_step, y_style)
            bbox = draw.textbbox((0, 0), label, font=font_tiny)
            lx = (bx0 + bx1) / 2 - (bbox[2] - bbox[0]) / 2
            if n > 0:
                ly = top_y - (bbox[3] - bbox[1]) - 4
                ly = max(top + 2, ly)
            else:
                ly = bot_y + 4
                ly = min(ly, top + plot_h - (bbox[3] - bbox[1]) - 2)
            draw.text((lx, ly), label, fill=pos_top if n > 0 else neg_top, font=font_tiny)

    def annotate(value: float, depth: float, name: str, color) -> None:
        if value == 0:
            return
        px = x_of(depth)
        py = y_of(value)
        draw.ellipse([px - 4, py - 4, px + 4, py + 4], fill=color)
        text = _format_peak(value, depth, y_style, name)
        bbox = draw.textbbox((0, 0), text, font=font_small)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        tx = min(max(px + 10, left + 8), left + plot_w - tw - 8)
        if value >= 0:
            ty = max(top + 8, py - th - 10)
        else:
            ty = min(py + 10, top + plot_h - th - 8)
        draw.text((tx, ty), text, fill=color, font=font_small)

    if y_style == "count":
        if actual_max > 0:
            annotate(actual_max, max_depth, "peak", pos_top)
    else:
        if actual_max > 0:
            annotate(actual_max, max_depth, "max", pos_top)
        if actual_min < 0:
            annotate(actual_min, min_depth, "min", neg_top)

    draw.rectangle([left, top, left + plot_w, top + plot_h], outline=_hex_rgb("#c5ccd4"), width=1)

    if span >= 0.2:
        x_fmt = lambda v: f"{v:.2f}"
    elif span >= 0.02:
        x_fmt = lambda v: f"{v:.3f}"
    else:
        x_fmt = lambda v: f"{v:.4f}"
    x_tick_count = max(8, min(16, plot_w // 140))
    for i in range(x_tick_count + 1):
        value = vmin + span * i / x_tick_count
        x = x_of(value)
        draw.line([(x, top + plot_h), (x, top + plot_h + 6)], fill=muted, width=1)
        label = x_fmt(value)
        bbox = draw.textbbox((0, 0), label, font=font_small)
        lx = x - (bbox[2] - bbox[0]) / 2
        lx = min(max(lx, left), left + plot_w - (bbox[2] - bbox[0]))
        draw.text((lx, top + plot_h + 12), label, fill=muted, font=font_small)

    draw.text((left, 22), title, fill=ink, font=font_title)
    draw.text((left, 58), subtitle, fill=muted, font=font_small)
    bbox = draw.textbbox((0, 0), xlabel, font=font)
    draw.text(
        (left + (plot_w - (bbox[2] - bbox[0])) / 2, height - 42),
        xlabel,
        fill=ink,
        font=font,
    )
    bbox = draw.textbbox((0, 0), ylabel, font=font)
    ylabel_img = Image.new("RGBA", (bbox[2] - bbox[0] + 4, bbox[3] - bbox[1] + 4), (0, 0, 0, 0))
    ImageDraw.Draw(ylabel_img).text((2, 2), ylabel, fill=ink, font=font)
    ylabel_img = ylabel_img.rotate(90, expand=True)
    image.paste(
        ylabel_img,
        (16, top + (plot_h - ylabel_img.size[1]) // 2),
        ylabel_img,
    )

    image.save(path)
    return bin_mm, peak, peak_depth
