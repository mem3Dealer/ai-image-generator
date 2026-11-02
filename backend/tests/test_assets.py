from pathlib import Path

ASSETS_DIR = Path(__file__).resolve().parents[1] / "assets"
STYLE_FILES = (
    "photorealistic.png",
    "digital-art.png",
    "anime.png",
    "cinematic.png",
)


def test_style_placeholders_are_distinct_pngs() -> None:
    contents: list[bytes] = []
    for file_name in STYLE_FILES:
        data = (ASSETS_DIR / file_name).read_bytes()
        assert data.startswith(b"\x89PNG\r\n\x1a\n")
        contents.append(data)
    assert len(set(contents)) == len(STYLE_FILES)
