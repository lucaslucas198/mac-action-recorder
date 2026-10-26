# dmgbuild settings: how the disk image window looks when it opens.
# Values come from make_dmg.sh via `dmgbuild -D app=... -D background=...`.
import os

app = defines["app"]            # noqa: F821  (provided by dmgbuild)
background = defines["background"]  # noqa: F821
app_name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

# The window is exactly the size of the background picture (660 x 400 points).
window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (165, 190),
    "Applications": (495, 190),
}
