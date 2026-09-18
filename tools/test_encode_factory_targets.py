import struct

import encode_factory


def test_s3_and_p4_palette_encodings_are_distinct_and_stable():
    colors = [
        (255, 0, 0),
        (0, 255, 0),
        (0, 0, 255),
        (255, 255, 255),
    ]

    assert encode_factory.encode_palette(colors, "s3") == bytes.fromhex(
        "00f8e0071f00ffff"
    )
    assert encode_factory.encode_palette(colors, "p4") == bytes.fromhex(
        "0000fc00fc00fc0000fcfcfc"
    )


def test_package_header_identifies_the_selected_hardware_target():
    frame = [(b"payload", encode_factory.CODEC_KEY, 0)]

    s3 = encode_factory.pack_ebaj(frame, fps=40, ss=480, target="s3")
    p4 = encode_factory.pack_ebaj(frame, fps=100, ss=480, target="p4")

    assert struct.unpack_from("<IH", s3, 0) == (0x344A4142, 4)
    assert struct.unpack_from("<IH", p4, 0) == (0x354A4142, 5)
    assert struct.unpack_from("<H", s3, 14)[0] == 40
    assert struct.unpack_from("<H", p4, 14)[0] == 100


def test_target_output_names_keep_s3_and_p4_files_separate(tmp_path):
    s3, p4 = encode_factory.target_output_paths(
        tmp_path / "animation_sd",
        tmp_path / "animation_sd_p4",
        "first_half",
        "F001",
    )

    assert s3 == tmp_path / "animation_sd" / "first_half" / "F001.eb4"
    assert p4 == tmp_path / "animation_sd_p4" / "first_half" / "F001.eb5"
