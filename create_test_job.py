#!/usr/bin/env python3
"""
207 Photo Workflow - Sports Team Test Job Creator (One-Click)
Creates a comprehensive sports team job folder that matches the app's expected format.
- Folders: Output, Extracted, Finished Teams, For Upload
- Images: camera-style originals in Extracted
- CSV in root with columns where indices used by the app are:
  [0]=original filename, [1]=firstName, [2]=lastName, [7]=groupName (team)
- Seeds: filename conflict, invalid filename, varied pose counts
"""

import os
import csv
import shutil
from pathlib import Path
import random
from PIL import Image, ImageDraw, ImageFont
import argparse

RANDOM = random.Random(207)

TEAMS = [
    ("Tigers", ["John Doe", "Amy Smith", "Carlos Reyes", "Mia Chen", "Evan Patel"]),
    ("Hawks", ["Liam Johnson", "Noah Davis", "Olivia Lee", "Emma Brown", "Ava Wilson"]),
    ("Sharks", ["Mason Clark", "Lucas Martinez", "Sophia Taylor", "Isabella Moore", "Mia Anderson"]),
]

CAMERA_PATTERNS = [
    ("IMG_{:04d}.JPG", 2000),
    ("DSC_{:04d}.JPG", 5000),
    ("P{:07d}.JPG", 1000000),
]


def create_test_image(path: Path, width=1600, height=1200, title="", subtitle=""):
    img = Image.new('RGB', (width, height))
    draw = ImageDraw.Draw(img)

    # gradient bg
    for y in range(height):
        r = int(40 + 180 * (y / height))
        g = int(90 + 120 * (1 - y / height))
        b = int(120 + 100 * (y / height))
        draw.line([(0, y), (width, y)], fill=(r, g, b))

    try:
        font_title = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 48)
        font_sub = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 28)
    except Exception:
        font_title = ImageFont.load_default()
        font_sub = ImageFont.load_default()

    text = title
    bbox = draw.textbbox((0, 0), text, font=font_title)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    x = (width - tw) // 2
    y = (height - th) // 2 - 20

    # shadow
    draw.text((x + 3, y + 3), text, fill=(0, 0, 0), font=font_title)
    draw.text((x, y), text, fill=(255, 255, 255), font=font_title)

    if subtitle:
        sbbox = draw.textbbox((0, 0), subtitle, font=font_sub)
        sw = sbbox[2] - sbbox[0]
        sh = sbbox[3] - sbbox[1]
        sx = (width - sw) // 2
        sy = y + th + 16
        draw.text((sx + 2, sy + 2), subtitle, fill=(0, 0, 0), font=font_sub)
        draw.text((sx, sy), subtitle, fill=(235, 235, 235), font=font_sub)

    img.save(path, 'JPEG', quality=85)


def next_camera_name(counter: int) -> str:
    pattern, base = RANDOM.choice(CAMERA_PATTERNS)
    return pattern.format(base + counter)


def create_sports_test_job(base_path: str):
    job_name = "2025_Youth_Baseball_League_TEST"
    job_path = Path(base_path).expanduser() / job_name

    # Clean existing
    if job_path.exists():
        shutil.rmtree(job_path)

    print(f"Creating sports test job at: {job_path}")

    # Required structure
    extracted = job_path / "Extracted"
    output = job_path / "Output"
    finished = job_path / "Finished Teams"
    for_upload = job_path / "For Upload"
    for p in [extracted, output, finished, for_upload]:
        p.mkdir(parents=True, exist_ok=True)

    # Generate images + CSV
    csv_path = job_path / "roster.csv"

    rows = []
    created_files = []
    counter = 1

    # Create per-team players with 2-4 poses each; vary counts to trigger pose validation
    for team, players in TEAMS:
        for player in players:
            first, last = player.split(" ", 1)
            pose_count = RANDOM.choice([2, 2, 3, 4])
            for pose_idx in range(1, pose_count + 1):
                cam_name = next_camera_name(counter)
                counter += 1
                img_path = extracted / cam_name
                title = f"{team}"
                subtitle = f"{player} - Pose {pose_idx}"
                create_test_image(img_path, title=title, subtitle=subtitle)
                created_files.append(cam_name)

                # CSV requires >= 8 columns; indices used: 0,1,2,7
                # [0]=original, [1]=first, [2]=last, [3-6]=unused, [6]=team (not used), [7]=group/team
                row = [
                    cam_name,            # 0 original
                    first,               # 1 firstName
                    last,                # 2 lastName
                    "", "", "",         # 3,4,5 unused
                    team,                # 6 teamName (not used by renamer)
                    team,                # 7 groupName (used as prefix)
                ]
                rows.append(row)

    # Seed a pre-existing file that matches a future new name to trigger conflict flag
    # Pick first player's first pose expected new name format: TEAM_FULLNAME_1.JPG
    conflict_team, players = TEAMS[0]
    conflict_player = players[0]
    first, last = conflict_player.split(" ", 1)
    conflict_newname = f"{conflict_team}_{first} {last}_1.JPG"
    conflict_path = extracted / conflict_newname
    create_test_image(conflict_path, title=f"{conflict_team}", subtitle=f"{conflict_player} (Existing)")

    # Add invalid filename to test validation warning
    invalid_name = "IMG:INVALID<>NAME.JPG"
    create_test_image(extracted / invalid_name, title="Invalid", subtitle="Filename")

    # Also duplicate mapping rows for same person to increase rename targets
    # (This won't set hasConflict pre-rename, but useful for volume and pose validation)
    rows.extend(rows[:5])

    # Write CSV with a simple header row for readability
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["original", "first", "last", "col4", "col5", "col6", "team", "group"])
        for r in rows:
            w.writerow(r)

    # Instructions
    readme = job_path / "TEST_INSTRUCTIONS.md"
    with open(readme, "w") as f:
        f.write(
            f"""
# 207 Photo Workflow - Sports Team Test Job

This job matches the app's expected structure and naming rules.

## Structure
- `Extracted/` (images here for renaming)
- `Output/` (empty)
- `Finished Teams/` (empty)
- `For Upload/` (empty)
- `roster.csv` in job root

## What's inside
- Teams: {', '.join(t for t, _ in TEAMS)}
- Players per team: 5
- Poses per player: 2-4 (varied to trigger pose count validation)
- Seeded conflict file in `Extracted/`: `{conflict_newname}`
- Invalid filename in `Extracted/`: `{invalid_name}`

## How to test
1) Select this folder as the job folder in the app.
2) In Rename Files:
   - Data Source: CSV (auto, since `roster.csv` exists)
   - Source Folder: Extracted
3) Run Preflight Validation
   - Should report write access ok
   - CSV format valid
   - Warnings for invalid filename
4) Analyze Files
   - Watch DetailedProgressView during analysis
   - See thumbnails and full preview/gallery
   - Try Show All Files and keyboard shortcuts (← → space esc)
5) Execute Rename
   - Try Dry Run + export report first
   - Then enable Backup and run actual rename
6) Undo from history if desired

Tip: To test Filename mode, temporarily rename `roster.csv` and Analyze again. Files are camera-style, so filename mode will not rename unless using existing TEAM_Player_Pose format.
"""
        )

    print(
        f"""
✅ Sports test job created successfully!

📁 Location: {job_path}
🖼️ Images: {len(created_files)} + conflict + invalid name
🧾 CSV: roster.csv with {len(rows)} rows

Open this folder as your job in the app and follow TEST_INSTRUCTIONS.md.
"""
    )


def main():
    parser = argparse.ArgumentParser(description='Create sports team test job for 207 Photo Workflow')
    parser.add_argument('--path', '-p', default=os.path.expanduser('~/Desktop'), help='Base path (default: ~/Desktop)')
    args = parser.parse_args()
    try:
        create_sports_test_job(args.path)
    except Exception as e:
        print(f"❌ Error: {e}")
        return 1
    return 0


if __name__ == '__main__':
    exit(main())
