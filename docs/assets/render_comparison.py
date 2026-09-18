"""Render an illustrative terminal comparison using measured demo counts."""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


WIDTH, HEIGHT = 1100, 462
BG = "#0b1018"
PANEL = "#121d2b"
BORDER = "#29384d"
TEXT = "#e4edf7"
MUTED = "#a0b0c6"
GREEN = "#7ce4b8"
AMBER = "#f6c778"
RED = "#ff929b"

SCENES = [
    {
        "selected": 0,
        "full": 48,
        "reason": "baseline matches",
        "result": "coverage holds",
        "saving": "48 repeated test executions avoided",
        "failed": False,
    },
    {
        "selected": 8,
        "full": 48,
        "reason": "1 test file selected",
        "result": "affected code: 100%",
        "saving": "40 repeated test executions avoided",
        "failed": False,
    },
    {
        "selected": 1,
        "full": 49,
        "reason": "1 test file selected",
        "result": "Demo.Dead: 0/2 lines",
        "saving": "Both reject the uncovered code",
        "failed": True,
    },
]


def font_path(explicit):
    candidates = [Path(explicit)] if explicit else [
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"),
        Path("/usr/share/fonts/dejavu/DejaVuSansMono.ttf"),
        Path("/System/Library/Fonts/Menlo.ttc"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    raise SystemExit("No monospace font found. Supply --font /path/to/font.ttf")


def render(scene, step, fonts):
    image = Image.new("RGB", (WIDTH, HEIGHT), BG)
    draw = ImageDraw.Draw(image)

    def text(x, y, value, color=TEXT, size=21):
        draw.text((x, y), value, font=fonts[size], fill=color)

    for left, x in [(True, 28), (False, 564)]:
        accent = GREEN if left else AMBER
        draw.rounded_rectangle((x, 24, x + 508, 394), radius=14, fill=PANEL, outline=BORDER, width=2)
        for dot, color in enumerate([RED, AMBER, GREEN]):
            draw.ellipse((x + 18 + dot * 19, 45, x + 27 + dot * 19, 54), fill=color)
        text(x + 98, 37, "with qlover" if left else "without qlover", accent)
        draw.line((x + 1, 73, x + 507, 73), fill=BORDER, width=1)
        command = "$ mix test.qlover" if left else "$ mix test --no-stale --cover"
        text(x + 20, 94, command)
        text(x + 20, 134, scene["reason"] if left else "full suite selected", MUTED)

        total = scene["selected"] if left else scene["full"]
        # A schematic progression of test counts, deliberately not a clock.
        count = min(total, step * 8)
        done = step >= 1 and count == total
        for test in range(scene["full"]):
            column, row = test % 25, test // 25
            color = accent if test < count else BORDER
            draw.rounded_rectangle(
                (x + 20 + column * 18, 179 + row * 20,
                 x + 30 + column * 18, 189 + row * 20),
                radius=2, fill=color,
            )

        text(x + 20, 234, f"{count} {'test' if count == 1 else 'tests'}", accent, 36)
        if done:
            failed = scene["failed"]
            text(x + 20, 292, "FAIL / coverage" if failed else "PASS / coverage", RED if failed else GREEN)
            detail = scene["result"] if left or failed else "full suite: 100%"
            text(x + 20, 332, detail, MUTED)
        else:
            text(x + 20, 292, "checking..." if step == 0 else "running tests...", MUTED)

    if step >= 7:
        text(28, 416, scene["saving"], GREEN if not scene["failed"] else RED, 24)
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font", help="Path to a monospace TTF/OTF/TTC font")
    args = parser.parse_args()
    path = font_path(args.font)
    fonts = {size: ImageFont.truetype(path, size) for size in [21, 24, 36]}
    output = Path(__file__).resolve().parent

    # Put a complete comparison first so even a non-animating preview is useful.
    frames = [render(SCENES[1], 7, fonts)]
    durations = [1800]
    for scene in SCENES:
        for step in range(8):
            frames.append(render(scene, step, fonts))
            durations.append(2400 if step == 7 else 450)

    # A shared palette avoids flicker when the GIF advances between frames.
    palette = frames[0].quantize(colors=128)
    frames = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
    frames[0].save(
        output / "comparison.gif", save_all=True, append_images=frames[1:],
        duration=durations, loop=0, optimize=True, disposal=2,
    )
    render(SCENES[1], 7, fonts).save(output / "comparison.png", optimize=True)
    print(f"Rendered {len(frames)} frames to {output / 'comparison.gif'}")


if __name__ == "__main__":
    main()
