#!/usr/bin/env python3
import numpy as np
import sys

width = 1920
height = 1080
input_file = sys.argv[1] if len(sys.argv) > 1 else "capture.raw"
output_file = input_file.replace('.raw', '.jpg')

# Read packed 10-bit data
packed = np.fromfile(input_file, dtype=np.uint8)
print(f"Read {len(packed)} bytes, Min:{packed.min()}, Max:{packed.max()}, Mean:{packed.mean():.1f}")

# Unpack 10-bit MIPI to 16-bit
bytes_per_row = (width * 10) // 8
packed = packed[:bytes_per_row * height].reshape(height, bytes_per_row)

img = np.zeros((height, width), dtype=np.uint16)
for y in range(height):
    for x in range(0, width, 4):
        i = (x * 10) // 8
        b0, b1, b2, b3, b4 = packed[y, i:i+5]
        img[y, x]     = (b0 << 2) | ((b4 >> 0) & 0x03)
        img[y, x + 1] = (b1 << 2) | ((b4 >> 2) & 0x03)
        img[y, x + 2] = (b2 << 2) | ((b4 >> 4) & 0x03)
        img[y, x + 3] = (b3 << 2) | ((b4 >> 6) & 0x03)

print(f"Unpacked 10-bit: Min:{img.min()}, Max:{img.max()}, Mean:{img.mean():.1f}")

# Stretch contrast
img_min, img_max = img.min(), img.max()
if img_max > img_min:
    img_stretched = ((img - img_min) * 1023 / (img_max - img_min)).astype(np.uint16)
else:
    img_stretched = img

# Convert to 8-bit
img8 = (img_stretched >> 2).astype(np.uint8)

# Debayer using OpenCV
try:
    import cv2
    bgr = cv2.cvtColor(img8, cv2.COLOR_BAYER_RG2BGR)
    bgr_bright = cv2.convertScaleAbs(bgr, alpha=2.0, beta=30)
    cv2.imwrite(output_file, bgr_bright)
    print(f"Saved {output_file}")
except ImportError:
    print("Install OpenCV: pip install opencv-python --break-system-packages")

