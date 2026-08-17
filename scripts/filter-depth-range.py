#!/usr/bin/env python3
"""Clip a 0–1 Float32 depth TIFF to a depth window and write a histogram.

Pixels outside [MIN, MAX] are set to 0. Captures from this app store distance
in meters; 0 already means invalid or outside the 0–1 m export window.

Requires: numpy and Pillow.

  pip install numpy pillow

Examples:
  ./scripts/filter-depth-range.py capture.tiff 0.30 0.45
  ./scripts/filter-depth-range.py capture.tiff 0.30 0.45 -o window.tiff --histogram hist.png
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

from depth_hist import auto_bin_count, load_float_tiff, save_float_tiff, write_bar_histogram


def write_histogram(
    path: Path,
    original: np.ndarray,
    vmin: float,
    vmax: float,
    bins: int,
    include_zeros: bool,
    kept_count: int,
    total_count: int,
) -> tuple[float, float, float]:
    window = original[
        np.isfinite(original) & (original >= vmin) & (original <= vmax)
    ]
    if not include_zeros:
        window = window[window != 0]

    edges = np.linspace(vmin, vmax, bins + 1)
    counts, _ = np.histogram(window, bins=edges)
    bin_mm = (vmax - vmin) / bins * 1000
    return write_bar_histogram(
        path,
        edges,
        counts.astype(np.float64),
        title=f"Depth {vmin:g}–{vmax:g} m  ·  {int(window.size):,} pixels in window",
        subtitle=(
            f"{bins:,} bins  ·  {bin_mm:.2f} mm each  ·  "
            f"{kept_count:,} / {total_count:,} of all pixels kept"
        ),
        xlabel="Depth (m)",
        ylabel="Pixels",
        y_style="count",
    )


def default_output_paths(input_path: Path, vmin: float, vmax: float) -> tuple[Path, Path]:
    stem = f"{input_path.stem}-{vmin:g}-{vmax:g}"
    parent = input_path.parent
    return parent / f"{stem}.tiff", parent / f"{stem}-histogram.png"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Set TIFF pixels outside MIN–MAX to 0 and write a depth histogram. "
            "Input should be a Float32 grayscale TIFF with values in meters (0–1)."
        )
    )
    parser.add_argument("input", type=Path, help="Float32 depth TIFF")
    parser.add_argument("min", type=float, help="Keep pixels >= this depth (meters)")
    parser.add_argument("max", type=float, help="Keep pixels <= this depth (meters)")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Filtered TIFF path (default: INPUT-MIN-MAX.tiff)",
    )
    parser.add_argument(
        "--histogram",
        type=Path,
        help="Histogram PNG path (default: INPUT-MIN-MAX-histogram.png)",
    )
    parser.add_argument(
        "--bins",
        type=int,
        default=None,
        help="Histogram bins (default: ~0.2 mm across the window, at least 400)",
    )
    parser.add_argument(
        "--include-zeros",
        action="store_true",
        help="Include 0-valued pixels in the histogram (they dominate otherwise)",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    vmin = args.min
    vmax = args.max
    if not np.isfinite(vmin) or not np.isfinite(vmax) or vmin > vmax:
        print("MIN and MAX must be finite numbers with MIN <= MAX.", file=sys.stderr)
        return 2
    if args.bins is None:
        args.bins = auto_bin_count(vmin, vmax)
    elif args.bins < 1:
        print("--bins must be at least 1.", file=sys.stderr)
        return 2
    if not args.input.is_file():
        print(f"No such file: {args.input}", file=sys.stderr)
        return 2

    output_tiff, output_hist = default_output_paths(args.input, vmin, vmax)
    if args.output is not None:
        output_tiff = args.output
    if args.histogram is not None:
        output_hist = args.histogram

    original = load_float_tiff(args.input)
    finite = np.isfinite(original)
    keep = finite & (original >= vmin) & (original <= vmax)
    filtered = np.where(keep, original, np.float32(0))

    output_tiff.parent.mkdir(parents=True, exist_ok=True)
    output_hist.parent.mkdir(parents=True, exist_ok=True)
    save_float_tiff(output_tiff, filtered)
    bin_mm, peak, peak_depth = write_histogram(
        output_hist,
        original,
        vmin,
        vmax,
        args.bins,
        args.include_zeros,
        int(keep.sum()),
        original.size,
    )

    nonzero_in = int((finite & (original != 0)).sum())
    print(f"Input:      {args.input}  {original.shape[1]}×{original.shape[0]}")
    print(f"Window:     {vmin:g}–{vmax:g} m")
    print(f"Kept:       {int(keep.sum()):,} / {original.size:,} pixels", end="")
    if nonzero_in:
        print(f"  ({int(keep.sum()) / nonzero_in:.1%} of nonzero samples)")
    else:
        print()
    print(f"TIFF:       {output_tiff}")
    print(
        f"Histogram:  {output_hist}  ({args.bins:,} bins, {bin_mm:.2f} mm, "
        f"peak {peak:,.0f} at {peak_depth:.4f} m)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
