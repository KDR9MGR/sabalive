# PK animation assets

The SVGA files in `assets/pk/` came from the owner's PK pack (2026-10-20). Everything in them is SVGA 2.x.

| File | What it is | Where the app plays it |
|---|---|---|
| `pk_matching` | red and blue rushing together, a "?" card | searching / waiting for the other host |
| `pk_svga` | crossed swords and "PK" | the incoming-invite card |
| `pk_start_anim` | the "PK" logo burst | the invite sheet's header |
| `pk_anim` | two gloves colliding | the countdown, above the 3-2-1 |
| `pk_count_down` | 3-2-1 (exactly 3 s) | the countdown |
| `room_battle_start_animator` | the "VS" burst | when the battle goes live |
| `live_pk` | the full-screen red / blue hero splash | optional intro behind the countdown (panel switch, off by default) |
| `pk_progress_red` / `pk_progress_blue` | the striped bar of each side | the tug-of-war score bar |
| `pk_progress_battle` | the shield and swords badge | where the two bars meet |
| `pk_mic_red` / `pk_mic_blue` (+ `_rtl`) | a red / blue sword | each end of the score bar (the `_rtl` ones in right-to-left languages) |
| `live_pk_win_icon` / `live_pk_lose_icon` / `live_pk_draw_icon` | the result badges | the result card |
| `lose` | a crying face on a ribbon | the result card, when the panel picks the "emoji" lose style |

`pk_progress_blue.svga` is not part of the pack: it is made from the red one by `make_progress_blue.py` (run it again if the
red file changes). The runtime colours (the panel's PK look) turn the hue of the red / blue files on screen, so these two sit
at hue 3 (red) and 203 (blue): `lib/features/live/widgets/pk_svga.dart` has the same numbers.
