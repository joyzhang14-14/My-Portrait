"""chrome.py 单元测试(确定性,不跑模型)。python3 test_chrome.py"""
import chrome

# 真实失败样本(2026-06-07 event[18]):菜单栏 chrome 把 4B 带偏成 Spotify
S254 = "Spotify File Edit View SATURDAY JUNE S M • • My-Portrait - Nc ..usly-skip-permissions -C 1f.assembleKeyst = +13 Uines （cl Read 1 file （ctru • buildInput 只算了： 文本比对。我读 Pas 1ID Read 1 file （ctrl • Pass4"
S265 = "Spotify File Edit View Playback Window Help Sat Jun 6 10:35 PM • My-Meeting 一• Learn how to request cc to replicate documenta MacBook Pro Speakers rpe SATURDAY 6 JUNE SM JUNE …..mentation - caffeinate"


def test_strip_real_samples():
    r254, r265 = chrome.strip_session_text(S254), chrome.strip_session_text(S265)
    assert "My-Portrait" in r254 and "文本比对" in r254 and "Pass4" in r254
    assert "File Edit View" not in r254
    assert "My-Meeting" in r265 and "caffeinate" in r265
    assert "File Edit View" not in r265
    assert "MacBook Pro Speakers" not in r265 and "10:35" not in r265


def test_noop_on_prose():
    prose = "Fixed the timeline arrow-key lag by switching to LazyHStack. Reviewed AnalyticsService.swift."
    assert chrome.strip_chrome(prose) == prose
    assert chrome.strip_chrome("I changed the View hierarchy in SwiftUI.") == \
        "I changed the View hierarchy in SwiftUI."


def test_labels_stripped():
    assert "Public Playlist" not in chrome.strip_chrome("Public Playlist Liked Songs")


def test_bg_media():
    assert chrome.is_background_media("Spotify", "", S254)
    assert chrome.is_background_media("Spotify", "", S265)
    assert not chrome.is_background_media("Terminal", "", S254)        # 非媒体
    assert not chrome.is_background_media(                              # 真音乐:无 dev token
        "Spotify", "", "Discover Weekly Release Radar 2010s rock playlist songs")
    assert not chrome.is_background_media("Spotify", "Now Playing", S254)  # 有 window


def test_sanity_net():
    # 长正文不该被清空(防 regex bug)
    long_prose = "Implemented the OCR accuracy booster feature. " * 10
    assert len(chrome.strip_session_text(long_prose)) > len(long_prose) * 0.5


if __name__ == "__main__":
    import sys
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"✓ {fn.__name__}")
    print(f"\n✅ {len(fns)} tests passed")
