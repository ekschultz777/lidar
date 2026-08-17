#!/usr/bin/env python3
"""Histogram A − B vs depth for two filtered Float32 depth TIFFs.

Same depth-window histogram as filter-depth-range.py, but each bar is the
sum of signed per-pixel depth differences (A − B) for samples in that bin.
Positive bars mean A is farther; negative bars mean A is closer.
Only pixels that are valid (finite, nonzero) in both images are compared.
Depth for binning is the mean of the two samples.

Requires: numpy and Pillow.

  pip install numpy pillow

Examples:
  ./scripts/diff-depth-histogram.py window-a.tiff window-b.tiff
  ./scripts/diff-depth-histogram.py window-a.tiff window-b.tiff 0.30 0.45
  ./scripts/diff-depth-histogram.py a.tiff b.tiff --histogram diff.png
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

from depth_hist import auto_bin_count, load_float_tiff, write_bar_histogram


def valid_mask(data: np.ndarray, include_zeros: bool) -> np.ndarray:
    mask = np.isfinite(data)
    if not include_zeros:
        mask &= data != 0
    return mask


def infer_window(depth: np.ndarray) -> tuple[float, float]:
    if depth.size == 0:
        raise SystemExit("No overlapping valid pixels to compare.")
    vmin = float(depth.min())
    vmax = float(depth.max())
    if vmax <= vmin:
        vmax = vmin + 1e-6
    return vmin, vmax


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Write a depth-window histogram whose bar heights are Σ (A − B) "
            "for two filtered Float32 depth TIFFs of the same size."
        )
    )
    parser.add_argument("image_a", type=Path, help="First filtered Float32 depth TIFF")
    parser.add_argument("image_b", type=Path, help="Second filtered Float32 depth TIFF")
    parser.add_argument(
        "min",
        type=float,
        nargs="?",
        help="Window min in meters (default: overlapping valid depths)",
    )
    parser.add_argument(
        "max",
        type=float,
        nargs="?",
        help="Window max in meters (default: overlapping valid depths)",
    )
    parser.add_argument(
        "--histogram",
        type=Path,
        help="Histogram PNG path (default: A-vs-B-diff-histogram.png)",
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
        help="Treat 0 as a valid depth when pairing pixels",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if (args.min is None) != (args.max is None):
        print("Provide both MIN and MAX, or neither.", file=sys.stderr)
        return 2
    if args.min is not None and (
        not np.isfinite(args.min) or not np.isfinite(args.max) or args.min > args.max
    ):
        print("MIN and MAX must be finite numbers with MIN <= MAX.", file=sys.stderr)
        return 2
    if args.bins is not None and args.bins < 1:
        print("--bins must be at least 1.", file=sys.stderr)
        return 2
    for path in (args.image_a, args.image_b):
        if not path.is_file():
            print(f"No such file: {path}", file=sys.stderr)
            return 2

    image_a = load_float_tiff(args.image_a)
    image_b = load_float_tiff(args.image_b)
    if image_a.shape != image_b.shape:
        print(
            f"Images must be the same size; got {image_a.shape[1]}×{image_a.shape[0]} "
            f"and {image_b.shape[1]}×{image_b.shape[0]}.",
            file=sys.stderr,
        )
        return 2

    both = valid_mask(image_a, args.include_zeros) & valid_mask(image_b, args.include_zeros)
    depth = (image_a + image_b) * 0.5
    delta = image_a.astype(np.float64) - image_b.astype(np.float64)

    if args.min is None:
        vmin, vmax = infer_window(depth[both])
    else:
        vmin, vmax = float(args.min), float(args.max)
        both &= (depth >= vmin) & (depth <= vmax)

    compared = int(both.sum())
    if compared == 0:
        print("No overlapping valid pixels to compare.", file=sys.stderr)
        return 2

    if args.bins is None:
        args.bins = auto_bin_count(vmin, vmax)

    edges = np.linspace(vmin, vmax, args.bins + 1)
    heights, _ = np.histogram(depth[both], bins=edges, weights=delta[both])
    bin_mm = (vmax - vmin) / args.bins * 1000
    mean_delta = float(delta[both].mean())
    output = args.histogram
    if output is None:
        output = args.image_a.parent / f"{args.image_a.stem}-vs-{args.image_b.stem}-diff-histogram.png"

    output.parent.mkdir(parents=True, exist_ok=True)
    _, peak, peak_depth = write_bar_histogram(
        output,
        edges,
        heights,
        title=f"A − B vs depth  ·  {vmin:g}–{vmax:g} m  ·  {compared:,} paired pixels",
        subtitle=(
            f"{args.bins:,} bins  ·  {bin_mm:.2f} mm each  ·  "
            f"mean Δ {mean_delta * 1000:+.3f} mm"
        ),
        xlabel="Depth (m)",
        ylabel="Σ (A − B) (m)",
        y_style="float",
    )

    print(f"A:          {args.image_a}  {image_a.shape[1]}×{image_a.shape[0]}")
    print(f"B:          {args.image_b}")
    print(f"Window:     {vmin:g}–{vmax:g} m")
    print(f"Paired:     {compared:,} / {image_a.size:,} pixels")
    print(f"Mean Δ:     {mean_delta * 1000:+.3f} mm")
    print(
        f"Histogram:  {output}  ({args.bins:,} bins, {bin_mm:.2f} mm, "
        f"extreme {peak:.6g} m at {peak_depth:.4f} m)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
