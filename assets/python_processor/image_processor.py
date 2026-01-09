#!/usr/bin/env python3
"""
Image Processing Python Sidecar
Compile with: pyinstaller --onefile --name image_processor image_processor.py
"""

import sys
import os
import json
from PIL import Image, ImageFilter, ImageEnhance, ImageDraw, ImageFont

def process_image(input_path, output_path):
    """
    Process image with various filters and enhancements.
    Returns status information via stdout as JSON.
    """
    try:
        # Validate input
        if not os.path.exists(input_path):
            raise FileNotFoundError(f"Input image not found: {input_path}")

        # Load image
        print(json.dumps({"status": "loading", "message": "Loading image..."}))
        img = Image.open(input_path)

        # Get original dimensions
        width, height = img.size
        print(json.dumps({
            "status": "info",
            "message": f"Image loaded: {width}x{height} pixels"
        }))

        # Apply processing pipeline
        print(json.dumps({"status": "processing", "message": "Applying filters..."}))

        # 1. Enhance sharpness
        enhancer = ImageEnhance.Sharpness(img)
        img = enhancer.enhance(1.5)

        # 2. Apply edge enhancement
        img = img.filter(ImageFilter.EDGE_ENHANCE)

        # 3. Adjust contrast
        enhancer = ImageEnhance.Contrast(img)
        img = enhancer.enhance(1.2)

        # 4. Apply subtle blur for smoothing
        img = img.filter(ImageFilter.SMOOTH)

        # 5. Add "SATORU GOJO" text overlay
        print(json.dumps({"status": "processing", "message": "Adding text overlay..."}))
        draw = ImageDraw.Draw(img)

        # Calculate font size based on image dimensions (5% of image height)
        font_size = int(height * 0.05)

        try:
            # Try to use a bold font if available (system-dependent)
            font = ImageFont.truetype("arial.ttf", font_size)
        except:
            try:
                # Fallback to different common font names
                font = ImageFont.truetype("Arial.ttf", font_size)
            except:
                # Use default PIL font as last resort
                font = ImageFont.load_default()

        text = "SATORU GOJO"

        # Get text bounding box for positioning
        bbox = draw.textbbox((0, 0), text, font=font)
        text_width = bbox[2] - bbox[0]
        text_height = bbox[3] - bbox[1]

        # Position text in the center of the image
        x = (width - text_width) // 2
        y = (height - text_height) // 2

        # Draw text with shadow effect for better visibility
        # Shadow (black outline)
        shadow_offset = max(2, font_size // 30)
        for offset_x in range(-shadow_offset, shadow_offset + 1):
            for offset_y in range(-shadow_offset, shadow_offset + 1):
                if offset_x != 0 or offset_y != 0:
                    draw.text((x + offset_x, y + offset_y), text, font=font, fill=(0, 0, 0, 255))

        # Main text (white with slight cyan tint - Gojo's signature color)
        draw.text((x, y), text, font=font, fill=(200, 230, 255, 255))

        # Save processed image
        print(json.dumps({"status": "saving", "message": "Saving processed image..."}))
        img.save(output_path, quality=95)

        # Get output file size
        file_size = os.path.getsize(output_path)
        file_size_mb = file_size / (1024 * 1024)

        # Return success with details
        result = {
            "status": "success",
            "message": "Image processed successfully",
            "details": {
                "input_path": input_path,
                "output_path": output_path,
                "dimensions": f"{width}x{height}",
                "file_size_mb": round(file_size_mb, 2)
            }
        }
        print(json.dumps(result))
        return 0

    except FileNotFoundError as e:
        error = {
            "status": "error",
            "message": str(e),
            "error_type": "FileNotFoundError"
        }
        print(json.dumps(error), file=sys.stderr)
        return 1

    except Exception as e:
        error = {
            "status": "error",
            "message": f"Processing failed: {str(e)}",
            "error_type": type(e).__name__
        }
        print(json.dumps(error), file=sys.stderr)
        return 2

def main():
    """Main entry point for the sidecar executable."""
    if len(sys.argv) != 3:
        error = {
            "status": "error",
            "message": "Usage: image_processor <input_path> <output_path>",
            "error_type": "InvalidArguments"
        }
        print(json.dumps(error), file=sys.stderr)
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2]

    exit_code = process_image(input_path, output_path)
    sys.exit(exit_code)

if __name__ == "__main__":
    main()