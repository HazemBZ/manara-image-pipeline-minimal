"""Pure image operations, independently testable without AWS."""

import io
import warnings

from PIL import Image, ImageDraw, ImageFont, ImageOps, UnidentifiedImageError

from pipeline.common import MAX_BYTES, MAX_PIXELS, MIME_FORMATS

Image.MAX_IMAGE_PIXELS = MAX_PIXELS


class InvalidImage(ValueError):
    """Rejected input; safe to report as a failed job, not retry forever."""


def decode(data, expected_mime=None):
    if not 0 < len(data) <= MAX_BYTES:
        raise InvalidImage("Image size is outside the allowed range")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as source:
                fmt = source.format
                if fmt not in MIME_FORMATS.values():
                    raise InvalidImage("Unsupported image format")
                if expected_mime and MIME_FORMATS[expected_mime] != fmt:
                    raise InvalidImage("Image content does not match its declared type")
                if source.width * source.height > MAX_PIXELS:
                    raise InvalidImage("Image exceeds the 20 megapixel limit")
                if getattr(source, "n_frames", 1) != 1:
                    raise InvalidImage("Animated images are not supported")
                source.load()
                oriented = ImageOps.exif_transpose(source).convert("RGBA")
                background = Image.new("RGB", oriented.size, "white")
                background.paste(oriented, mask=oriented.getchannel("A"))
                # Copy pixels only: do not carry EXIF, GPS, XMP, or other input metadata.
                clean = Image.new("RGB", background.size)
                clean.paste(background)
                return clean, fmt
    except (
        UnidentifiedImageError,
        OSError,
        Image.DecompressionBombError,
        Image.DecompressionBombWarning,
    ) as error:
        raise InvalidImage("Image is corrupt or unsafe to decode") from error


def jpeg(image):
    output = io.BytesIO()
    image.save(output, format="JPEG", quality=88, optimize=True)
    return output.getvalue()


def resized(image, size):
    result = image.copy()
    result.thumbnail(size, Image.Resampling.LANCZOS)
    return result


def watermarked(image, text):
    image = image.copy().convert("RGBA")
    overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    size = max(8, min(36, image.width // 18))
    font = ImageFont.load_default(size=size)
    bounds = draw.textbbox((0, 0), text, font=font)
    text_width, text_height = bounds[2] - bounds[0], bounds[3] - bounds[1]
    margin = max(2, image.width // 50)
    x = max(0, image.width - text_width - margin * 2)
    y = max(0, image.height - text_height - margin * 2)
    draw.rounded_rectangle(
        (x, y, min(image.width, x + text_width + margin * 2), image.height),
        radius=margin,
        fill=(10, 20, 30, 145),
    )
    draw.text((x + margin - bounds[0], y + margin - bounds[1]), text, font=font, fill="white")
    return Image.alpha_composite(image, overlay).convert("RGB")
