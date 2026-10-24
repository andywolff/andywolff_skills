#!/usr/bin/env python3
"""
Standalone visual differential comparator for images (PNG, JPEG, etc.).
Runs independently of Flutter test harnesses using Pillow (if available)
or native macOS `sips` conversion.

Usage:
    python3 diff_images.py --baseline <file> --candidate <file> [options]

Options:
    --baseline <path>       Path to baseline reference image (required)
    --candidate <path>      Path to candidate image (required)
    --diff <path>           Path to save output visual difference heatmap PNG
    --crop <l,t,r,b>        Crop bounding box coordinates: left,top,right,bottom
    --threshold <delta>     Maximum channel delta tolerance before marking a diff (default: 0)
"""

import argparse
import os
import struct
import subprocess
import sys
import tempfile
import zlib


def write_png(width, height, rgba_bytes, output_path):
    """Encodes raw RGBA bytes into an uncompressed/deflated PNG file."""
    raw_scanlines = bytearray()
    row_stride = width * 4
    for y in range(height):
        raw_scanlines.append(0)  # Filter type 0 (None)
        start = y * row_stride
        raw_scanlines.extend(rgba_bytes[start : start + row_stride])

    compressed = zlib.compress(bytes(raw_scanlines))

    png = bytearray(b"\x89PNG\r\n\x1a\n")
    # IHDR
    ihdr_data = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    ihdr_crc = struct.pack(">I", zlib.crc32(b"IHDR" + ihdr_data))
    png.extend(struct.pack(">I", 13) + b"IHDR" + ihdr_data + ihdr_crc)

    # IDAT
    idat_len = struct.pack(">I", len(compressed))
    idat_crc = struct.pack(">I", zlib.crc32(b"IDAT" + compressed))
    png.extend(idat_len + b"IDAT" + compressed + idat_crc)

    # IEND
    iend_crc = struct.pack(">I", zlib.crc32(b"IEND"))
    png.extend(struct.pack(">I", 0) + b"IEND" + iend_crc)

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, "wb") as f:
        f.write(png)


def load_image_via_sips(image_path):
    """Loads an image into raw RGBA bytes and (width, height) using macOS sips."""
    with tempfile.NamedTemporaryFile(suffix=".bmp", delete=False) as tmp_bmp:
        tmp_bmp_path = tmp_bmp.name

    try:
        proc = subprocess.run(
            ["sips", "-s", "format", "bmp", image_path, "--out", tmp_bmp_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"sips conversion failed: {proc.stderr}")

        with open(tmp_bmp_path, "rb") as f:
            data = f.read()

        if len(data) < 54 or data[:2] != b"BM":
            raise ValueError(f"Invalid BMP format generated for {image_path}")

        pixel_offset = struct.unpack("<I", data[10:14])[0]
        width, height = struct.unpack("<ii", data[18:26])
        bpp = struct.unpack("<H", data[28:30])[0]

        top_down = False
        if height < 0:
            top_down = True
            height = -height

        if bpp not in (24, 32):
            raise ValueError(f"Unsupported BMP bits-per-pixel: {bpp}")

        rgba = bytearray(width * height * 4)
        bytes_per_pixel = bpp // 8
        row_bytes = width * bytes_per_pixel
        padding = (4 - (row_bytes % 4)) % 4
        stride = row_bytes + padding

        for y in range(height):
            src_y = y if top_down else (height - 1 - y)
            row_start = pixel_offset + src_y * stride
            dst_row_start = y * width * 4

            for x in range(width):
                px_idx = row_start + x * bytes_per_pixel
                dst_idx = dst_row_start + x * 4

                b = data[px_idx]
                g = data[px_idx + 1]
                r = data[px_idx + 2]
                a = data[px_idx + 3] if bytes_per_pixel == 4 else 255

                rgba[dst_idx] = r
                rgba[dst_idx + 1] = g
                rgba[dst_idx + 2] = b
                rgba[dst_idx + 3] = a

        return width, height, bytes(rgba)

    finally:
        if os.path.exists(tmp_bmp_path):
            os.unlink(tmp_bmp_path)


def load_image(image_path):
    """Attempts loading image via PIL if available, falling back to sips."""
    try:
        from PIL import Image

        with Image.open(image_path) as img:
            img = img.convert("RGBA")
            return img.width, img.height, img.tobytes()
    except ImportError:
        return load_image_via_sips(image_path)


def main():
    parser = argparse.ArgumentParser(
        description="Standalone visual differential comparator for images."
    )
    parser.add_argument("--baseline", required=True, help="Baseline reference image")
    parser.add_argument("--candidate", required=True, help="Candidate image to compare")
    parser.add_argument("--diff", help="Output path for visual diff heatmap PNG")
    parser.add_argument(
        "--crop",
        help="Comma-separated crop coordinates: left,top,right,bottom (e.g. 0,0,100,100)",
    )
    parser.add_argument(
        "--threshold",
        type=int,
        default=0,
        help="Channel delta threshold before flagging mismatch (default: 0)",
    )

    args = parser.parse_args()

    if not os.path.isfile(args.baseline):
        sys.exit(f"❌ Error: Baseline image not found: {args.baseline}")
    if not os.path.isfile(args.candidate):
        sys.exit(f"❌ Error: Candidate image not found: {args.candidate}")

    w1, h1, pixels1 = load_image(args.baseline)
    w2, h2, pixels2 = load_image(args.candidate)

    if w1 != w2 or h1 != h2:
        print(f"⚠️ Warning: Dimensions differ! Baseline: {w1}x{h1}, Candidate: {w2}x{h2}")

    crop_l, crop_t = 0, 0
    crop_r, crop_b = min(w1, w2), min(h1, h2)

    if args.crop:
        try:
            parts = [int(p.strip()) for p in args.crop.split(",")]
            if len(parts) == 4:
                crop_l = max(0, min(parts[0], crop_r))
                crop_t = max(0, min(parts[1], crop_b))
                crop_r = max(crop_l, min(parts[2], crop_r))
                crop_b = max(crop_t, min(parts[3], crop_b))
            else:
                sys.exit("❌ Error: --crop must have 4 comma-separated values: left,top,right,bottom")
        except ValueError:
            sys.exit("❌ Error: Invalid integer coordinates in --crop")

    region_w = crop_r - crop_l
    region_h = crop_b - crop_t

    if region_w <= 0 or region_h <= 0:
        sys.exit(f"❌ Error: Invalid crop region: {region_w}x{region_h}")

    diff_pixels = bytearray(region_w * region_h * 4)
    baseline_crop = bytearray(region_w * region_h * 4)
    candidate_crop = bytearray(region_w * region_h * 4)

    total_diff_count = 0
    max_delta = 0
    min_x, max_x = 999999, -1
    min_y, max_y = 999999, -1
    threshold = args.threshold

    for y in range(region_h):
        src_y = crop_t + y
        dst_y_offset = y * region_w * 4
        src1_y_offset = src_y * w1 * 4
        src2_y_offset = src_y * w2 * 4

        for x in range(region_w):
            src_x = crop_l + x
            src1_idx = src1_y_offset + src_x * 4
            src2_idx = src2_y_offset + src_x * 4
            dst_idx = dst_y_offset + x * 4

            r1, g1, b1, a1 = pixels1[src1_idx : src1_idx + 4]
            r2, g2, b2, a2 = pixels2[src2_idx : src2_idx + 4]

            baseline_crop[dst_idx : dst_idx + 4] = [r1, g1, b1, a1]
            candidate_crop[dst_idx : dst_idx + 4] = [r2, g2, b2, a2]

            dr = abs(r1 - r2)
            dg = abs(g1 - g2)
            db = abs(b1 - b2)
            da = abs(a1 - a2)
            delta = max(dr, dg, db, da)

            if delta > max_delta:
                max_delta = delta

            if delta > threshold:
                total_diff_count += 1
                if x < min_x:
                    min_x = x
                if x > max_x:
                    max_x = x
                if y < min_y:
                    min_y = y
                if y > max_y:
                    max_y = y

                # Highlight mismatch in magenta
                diff_pixels[dst_idx : dst_idx + 4] = [255, 0, 128, 255]
            else:
                # Dimmed grayscale for matching pixels
                gray = round((r1 + g1 + b1) / 3)
                diff_pixels[dst_idx : dst_idx + 4] = [gray, gray, gray, 60]

    total_pixels = region_w * region_h
    diff_pct = (total_diff_count / total_pixels) * 100.0

    print("------------------------------------------------------------")
    print("Visual Differential Results:")
    print(f"  Region Size:       {region_w}x{region_h} ({total_pixels} px)")
    print(f"  Mismatched Pixels: {total_diff_count} / {total_pixels} ({diff_pct:.2f}%)")
    print(f"  Max Channel Delta: {max_delta}")
    if total_diff_count > 0:
        print(f"  Diff Bounding Box: x=[{min_x}..{max_x}], y=[{min_y}..{max_y}]")
    print("------------------------------------------------------------")

    if args.diff:
        base_path = args.diff[:-4] if args.diff.endswith(".png") else args.diff
        write_png(region_w, region_h, diff_pixels, args.diff)
        print(f"Diff heatmap saved to: {args.diff}")

        if args.crop:
            base_crop_path = f"{base_path}_baseline_crop.png"
            cand_crop_path = f"{base_path}_candidate_crop.png"
            write_png(region_w, region_h, baseline_crop, base_crop_path)
            write_png(region_w, region_h, candidate_crop, cand_crop_path)
            print(f"Cropped baseline saved to: {base_crop_path}")
            print(f"Cropped candidate saved to: {cand_crop_path}")

    if total_diff_count > 0:
        print("❌ FAILED: Images differ.")
        sys.exit(1)
    else:
        print("✅ PASSED: Images are visually identical.")
        sys.exit(0)


if __name__ == "__main__":
    main()
