#!/usr/bin/env python3
"""Edit reviewed UI captures: uv run --with pillow scripts/edit-demo.py SOURCE_DIR.

FFmpeg makes the cuts, crossfades and H.264 fast-start MP4. Pillow lays out
the caption cards. Originals stay outside public/; only the reviewed edit ships.
"""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[1]
SCENES = [
    ("01-recorder.png", "Choose an app. Keep working.", "No task prompt. No room code. Start observing on your Mac.", "NATIVE RECORDER"),
    ("02-mail-general.png", "Work in the app you already use.", "Mail settings walkthrough. No messages sent or preferences changed.", "MAIL INTERFACE WALKTHROUGH"),
    ("03-mail-viewing.png", "Move between screens naturally.", "The recorder pauses whenever the selected app loses focus.", "MAIL INTERFACE WALKTHROUGH"),
    ("05-captured-mail.jpg", "Keep the evidence in scope.", "A real ScreenCaptureKit frame containing only Mail's window.", "ACTUAL LOCAL CAPTURE"),
    ("06-review.png", "Review before you share.", "Inspect frames and omit sensitive evidence before Upload & Analyze.", "ACTUAL LOCAL REVIEW"),
    ("07-graph.png", "Inspect the map. Follow the evidence.", "Separate synthetic fixture analyzed by Nemotron; this is not Mail analysis.", "SYNTHETIC ANALYSIS FIXTURE"),
]


def run(*args):
    subprocess.run(args, check=True)


def vtt_time(seconds):
    milliseconds = round(seconds * 1000)
    return f"00:{milliseconds // 60000:02}:{milliseconds // 1000 % 60:02}.{milliseconds % 1000:03}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        parser.error("Install FFmpeg and ffprobe first")
    for filename, *_ in SCENES:
        if not (args.source / filename).is_file():
            parser.error(f"Missing reviewed source: {filename}")
    output = ROOT / "web/public/demo"
    output.mkdir(parents=True, exist_ok=True)
    font_dir = Path("/System/Library/Fonts/Supplemental")
    title_font = ImageFont.truetype(str(font_dir / "Arial Bold.ttf"), 45)
    body_font = ImageFont.truetype(str(font_dir / "Arial.ttf"), 20)
    tag_font = ImageFont.truetype(str(font_dir / "Arial Bold.ttf"), 13)
    with tempfile.TemporaryDirectory(prefix="retrace-demo-") as temporary:
        work = Path(temporary)
        cards = []
        for index, (filename, title, subtitle, tag) in enumerate(SCENES):
            card = Image.new("RGB", (1280, 720), "#08090b")
            draw = ImageDraw.Draw(card)
            draw.text((54, 40), title, font=title_font, fill="#f5f5f6")
            draw.text((56, 105), subtitle, font=body_font, fill="#a7a7b0")
            shot = Image.open(args.source / filename).convert("RGB")
            if filename in {"02-mail-general.png", "03-mail-viewing.png"}:
                shot = shot.crop((0, 45, shot.width, min(850, shot.height)))
            elif filename == "05-captured-mail.jpg":
                # This reviewed capture has a white area outside the app window.
                shot = shot.crop((0, 0, 1348, min(850, shot.height)))
            elif filename == "07-graph.png":
                shot = shot.crop((232, 100, 940, 670))
            elif filename == "06-review.png":
                shot = shot.crop((490, 80, shot.width - 20, shot.height - 35))
            shot = ImageOps.contain(shot, (1168, 484), Image.Resampling.LANCZOS)
            x, y = (1280 - shot.width) // 2, 158 + (484 - shot.height) // 2
            mask = Image.new("L", shot.size, 0)
            ImageDraw.Draw(mask).rounded_rectangle((0, 0, shot.width - 1, shot.height - 1), radius=10, fill=255)
            card.paste(shot, (x, y), mask)
            draw.rounded_rectangle((x - 1, y - 1, x + shot.width, y + shot.height), radius=10, outline="#393a40", width=1)
            draw.line((56, 664, 1224, 664), fill="#25262b")
            draw.text((56, 683), f"0{index + 1}  /  {tag}", font=tag_font, fill="#ff9774")
            draw.text((1135, 680), "Retrace", font=body_font, fill="#f5f5f6")
            target = work / f"card-{index}.png"
            card.save(target)
            cards.append(target)
            if index == 0:
                card.save(output / "poster.webp", quality=84, method=6)
        command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
        for card in cards:
            command.extend(["-loop", "1", "-framerate", "30", "-t", "4", "-i", str(card)])
        filters = [f"[{i}:v]format=yuv420p,settb=AVTB,setpts=PTS-STARTPTS[v{i}]" for i in range(len(cards))]
        previous = "v0"
        for index in range(1, len(cards)):
            next_label = f"f{index}"
            filters.append(f"[{previous}][v{index}]xfade=transition=fade:duration=0.4:offset={index * 3.6:.1f}[{next_label}]")
            previous = next_label
        command.extend(["-filter_complex_threads", "1", "-filter_complex", ";".join(filters), "-map", f"[{previous}]", "-c:v", "libx264", "-preset", "slow", "-crf", "22", "-pix_fmt", "yuv420p", "-r", "30", "-an", "-movflags", "+faststart", str(output / "retrace-demo.mp4")])
        run(*command)
    captions = ["WEBVTT", ""]
    for index, (_, title, subtitle, _) in enumerate(SCENES):
        start = index * 3.6
        end = min((index + 1) * 3.6, 22) if index < 5 else 22
        captions.extend([f"{vtt_time(start)} --> {vtt_time(end)}", title, subtitle, ""])
    (output / "captions.vtt").write_text("\n".join(captions))
    info = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", str(output / "retrace-demo.mp4")]))
    stream = next(s for s in info["streams"] if s["codec_type"] == "video")
    assert (stream["width"], stream["height"]) == (1280, 720)
    assert stream["codec_name"] == "h264" and stream["pix_fmt"] == "yuv420p"
    assert 21.8 <= float(info["format"]["duration"]) <= 22.2
    print(json.dumps({"seconds": info["format"]["duration"], "mp4_bytes": (output / "retrace-demo.mp4").stat().st_size, "poster_bytes": (output / "poster.webp").stat().st_size}))


if __name__ == "__main__":
    main()
