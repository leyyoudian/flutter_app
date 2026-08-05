import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "encode_factory",
    ROOT / "tools" / "encode_factory.py",
)
encode_factory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(encode_factory)


def test_choose_preview_frame_prefers_most_visible_frame():
    with TemporaryDirectory() as tmp:
        root = Path(tmp)
        black = root / "black.png"
        small = root / "small.png"
        large = root / "large.png"

        Image.new("RGB", (120, 120), (0, 0, 0)).save(black)
        small_img = Image.new("RGB", (120, 120), (0, 0, 0))
        for x in range(55, 65):
            for y in range(55, 65):
                small_img.putpixel((x, y), (0, 255, 0))
        small_img.save(small)
        Image.new("RGB", (120, 120), (0, 255, 0)).save(large)

        assert encode_factory.choose_preview_frame([black, small, large]) == large
