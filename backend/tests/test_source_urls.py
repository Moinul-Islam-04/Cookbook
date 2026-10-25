import pytest

from app.source_urls import UnsupportedSourceUrl, parse_instagram_url, parse_source_url

CODE = "C1a2B3c4D5e"


@pytest.mark.parametrize(
    "url, kind",
    [
        (f"https://www.instagram.com/p/{CODE}/", "p"),
        (f"https://www.instagram.com/p/{CODE}", "p"),
        (f"https://instagram.com/reel/{CODE}/?igsh=MTc4bWx0&utm_source=ig_web_copy_link", "reel"),
        (f"http://m.instagram.com/reels/{CODE}#comments", "reel"),
        (f"https://www.instagram.com/some.chef_99/reel/{CODE}/", "reel"),
        (f"instagram.com/p/{CODE}", "p"),
        (f"  HTTPS://WWW.INSTAGRAM.COM/p/{CODE}/  ", "p"),
        (f"https://www.instagram.com/tv/{CODE}/", "p"),
    ],
)
def test_recognized_links_normalize_to_one_post_key(url: str, kind: str) -> None:
    post = parse_instagram_url(url)
    assert post.post_key == f"instagram:{CODE}"
    assert post.canonical_url == f"https://www.instagram.com/{kind}/{CODE}/"


def test_shortcode_case_is_preserved() -> None:
    # Shortcodes are case-sensitive: these are different posts.
    assert parse_instagram_url("instagram.com/p/AbCdEfGhIjK").post_key != parse_instagram_url(
        "instagram.com/p/abcdefghijk"
    ).post_key


@pytest.mark.parametrize(
    "url",
    [
        "https://www.tiktok.com/@chef/video/123",
        "https://evil.example/www.instagram.com/p/C1a2B3c4D5e/",
        "https://www.instagram.com.evil.example/p/C1a2B3c4D5e/",
        "https://user:pass@www.instagram.com/p/C1a2B3c4D5e/",
        "https://www.instagram.com:8443/p/C1a2B3c4D5e/",
        "ftp://www.instagram.com/p/C1a2B3c4D5e/",
        "javascript:alert(1)",
        "https://www.instagram.com/some.chef/",
        "https://www.instagram.com/explore/tags/pasta/",
        "https://www.instagram.com/p/",
        "https://www.instagram.com/p/C1a2B3c4D5e/extra/",
        "https://www.instagram.com/p/bad*code/",
        "https://www.instagram.com/p/" + "a" * 2100,
        "not a url",
    ],
)
def test_unsupported_links_are_rejected(url: str) -> None:
    with pytest.raises(UnsupportedSourceUrl):
        parse_instagram_url(url)


TIKTOK_ID = "7301234567890123456"


@pytest.mark.parametrize(
    "url, canonical",
    [
        (f"https://www.tiktok.com/@chef.ann/video/{TIKTOK_ID}", f"https://www.tiktok.com/@chef.ann/video/{TIKTOK_ID}"),
        (f"https://www.tiktok.com/@chef.ann/video/{TIKTOK_ID}?is_from_webapp=1&sender_device=pc", f"https://www.tiktok.com/@chef.ann/video/{TIKTOK_ID}"),
        (f"tiktok.com/@chef_ann/video/{TIKTOK_ID}/", f"https://www.tiktok.com/@chef_ann/video/{TIKTOK_ID}"),
        (f"https://m.tiktok.com/@chef.ann/photo/{TIKTOK_ID}", f"https://www.tiktok.com/@chef.ann/photo/{TIKTOK_ID}"),
    ],
)
def test_tiktok_links_normalize_to_the_video_id(url: str, canonical: str) -> None:
    post = parse_source_url(url)
    assert post.post_key == f"tiktok:{TIKTOK_ID}"
    assert post.canonical_url == canonical
    assert post.author_handle in ("chef.ann", "chef_ann")


def test_instagram_links_still_parse_through_the_shared_parser() -> None:
    assert parse_source_url(f"https://www.instagram.com/some.chef_99/reel/{CODE}/").author_handle == "some.chef_99"
    assert parse_source_url(f"instagram.com/p/{CODE}").post_key == f"instagram:{CODE}"


@pytest.mark.parametrize(
    "url",
    [
        "https://vm.tiktok.com/ZMabc123/",
        "https://vt.tiktok.com/ZSabc123/",
        "https://www.tiktok.com/t/ZTabc123/",
        "https://www.tiktok.com/@chef",
        "https://www.tiktok.com/@chef/video/123",
        "https://www.tiktok.com/@chef/video/7301234567890123456/extra",
        "https://www.tiktok.com/@chef/live",
        "https://www.tiktok.com.evil.example/@chef/video/7301234567890123456",
        "https://www.tiktok.com:8443/@chef/video/7301234567890123456",
        "https://www.youtube.com/watch?v=abc",
    ],
)
def test_unsupported_links_are_rejected_by_the_shared_parser(url: str) -> None:
    with pytest.raises(UnsupportedSourceUrl):
        parse_source_url(url)
