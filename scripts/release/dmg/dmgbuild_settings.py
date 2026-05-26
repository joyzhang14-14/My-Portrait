"""dmgbuild config for MyPortrait DMG.

读环境变量:
  DMG_APP_PATH:    .app 绝对路径
  DMG_VOLUME_NAME: mount 后的 volume 名(显示在 Finder 顶上)
  DMG_BADGE_ICON:  .icns 路径(可选,给 volume icon 打 badge)

布局: 660x400 窗口,左边 .app icon,右边 Applications symlink。用户拖
左到右就装好。
"""
import os

APP_PATH = os.environ.get('DMG_APP_PATH', '')
VOLUME_NAME = os.environ.get('DMG_VOLUME_NAME', 'My Portrait')
BADGE_ICON = os.environ.get('DMG_BADGE_ICON', '')

# DMG 元数据
volume_name = VOLUME_NAME
format = 'UDZO'
compression_level = 9

# 内容
files = [APP_PATH] if APP_PATH else []
symlinks = {'Applications': '/Applications'}

# 窗口尺寸 ((left, top), (right, bottom))
window_rect = ((100, 100), (760, 500))

# Icon 尺寸(points)
icon_size = 128

# Icon 位置:左 .app,右 Applications。两个图标垂直居中,水平分两等份。
app_basename = os.path.basename(APP_PATH) if APP_PATH else 'MyPortrait.app'
icon_locations = {
    app_basename: (170, 180),
    'Applications': (490, 180),
}

# 不显示 Finder 工具栏 / 状态栏 / tab(干净的"拖一拖装好"窗口)
show_statusbar = False
show_tabview = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# 给 mount 后的 volume 配一个 icon(用 app 自己的 .icns)
if BADGE_ICON and os.path.exists(BADGE_ICON):
    badge_icon = BADGE_ICON
