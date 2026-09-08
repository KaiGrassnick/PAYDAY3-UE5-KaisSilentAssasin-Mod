# KaisSilentAssasin

A PAYDAY 3 mod. A guard only calls in a pager if it was actually aware of a
heister when it died — and optionally, how many pagers you may answer before
the search starts.

Written for **PAYDAY 3 on Unreal Engine 5.5.4** (`++payday3+candidate_PATCH3_8`),
as a UE4SS Lua mod.

---

## Behaviour

| Guard's state when killed | Pager |
|---|---|
| Never noticed anything | silent |
| Was suspicious, then lost you | silent (configurable) |
| Suspicious right now | rings |
| Fully detected you at any point | rings, permanently |

Full detection is a one-way latch: once a guard has identified a heister it can
page even if it later calms down. Partial suspicion is reversible by default —
a guard that got curious and then lost interest is a silent kill again.

Separately, `MaxPagerAnswers` lowers how many pagers you may answer before the
search starts. The HUD radio counter follows it.

---

## Requirements

**PD3 UE4SS (the PAYDAY 3-specific build)** — <https://modworkshop.net/mod/47771>

> The generic RE-UE4SS release **does not work**. It crashes PAYDAY 3 at
> startup with `EXCEPTION_ACCESS_VIOLATION reading 0x144` while inspecting the
> first constructed `UObject`, because it lacks the PD3-specific
> `MemberVariableLayout.ini` / `VTableLayout.ini` offsets. Use the PD3 build.

---

## Install

1. Install PD3 UE4SS: extract it into
   `<game>\PAYDAY3\PAYDAY3\Binaries\Win64\` so `dwmapi.dll` sits next to
   `PAYDAY3-Win64-Shipping.exe`, with the `UE4SS` folder beside it.

2. Download the latest: KaisSilentAssasin.zip from the latest release ([GitHub Release Page](https://github.com/KaiGrassnick/PAYDAY3-UE5-KaisSilentAssasin-Mod/releases))
3. Extract / Copy the containing folder (KaisSilentAssasin) into `...\Binaries\Win64\UE4SS\Mods\`, giving:

       UE4SS\Mods\KaisSilentAssasin\config.ini
       UE4SS\Mods\KaisSilentAssasin\enabled.txt
       UE4SS\Mods\KaisSilentAssasin\Scripts\main.lua

`enabled.txt` is what switches the mod on. Adding `KaisSilentAssasin : 1` to
`UE4SS\Mods\mods.txt` does the same job; either is enough.

To disable without deleting: remove `enabled.txt`, or set `: 0` in `mods.txt`.

---

## Configuration

`config.ini` sits beside `main.lua`'s folder and is **re-read at every heist
start** — edits apply on the next heist, no game restart. The mod writes a
fully commented default if the file is missing. Unknown keys and unparseable
values fall back to the default and are reported in the log.

| Key | Default | Meaning |
|---|---|---|
| `ResetOnSuspicionLost` | `true` | `false` = hardcore: any suspicion above the threshold, ever, lets that guard page for the rest of the heist |
| `SuspicionThreshold` | `0.0` | Suspicion progress (0.0–1.0) that counts as "saw me". `0.0` means even a 0.0004 flicker counts; raise it to ignore brief glances |
| `LogToFile` | `false` | Write `KaisSilentAssasin.log` in the mod folder |
| `LogToUE4SSLog` | `false` | Write the same lines to `UE4SS.log` / console (independent of the above) |
| `TruncateLogOnHeistStart` | `true` | One heist per log file; `false` appends and grows without bound |
| `MaxPagerAnswers` | `-1` | `-1` stock, `0` first answered pager starts the search, `1` one safe answer, `2` two, … **Lowering only** |

---

## How it works

**Pager suppression.** The game arms the pager in native code with no event to
intercept, so instead of blocking the call the mod decides in advance whether
each guard is *capable* of paging, and flips that as its awareness changes:

    guard spawns                    -> bIsPagerSnatched = true  (cannot page)
    suspicion above threshold       -> restored                 (can page)
    suspicion back below threshold  -> snatched again
    full detection                  -> restored for good

`bIsPagerSnatched` is the game's own native "this guard has no pager" state —
the one behind the snatch-a-pager mechanic — not an invented flag.

**Pager allowance.** The cap itself cannot be written, so the
mod spends answers instead, on `AnswerPagerCount`. With `n` answers already
made when the maximum becomes known:

    AnswerPagerCount = live_max - want + n

makes answer number `want + 1` the one that starts the search, counting from
the start of the heist. The maximum comes from the HUD widget, which reports
it when it first draws at heist start, so normally `n = 0` and the cap lands
before any pager can be answered. `MaxPagerAnswers = 0` needs no maximum and
pushes the counter to 250.

**HUD counter.** The radio counter is a rich-text label the widget writes
through the native `RichTextBlock:SetText`, as text like
`<DefaultValue>3</> radios until Search`. That native function can be hooked
before and after the call, so the mod lets the game draw and then re-sets the
`<Tag>digit</>` token from the live count. The widget's own graph is never
called, which is what caused the redraw ping-pong of the earlier attempt. With
`r` safe answers left the label reads `r + 1`, so 1 means the next answer
starts the search, and it reads 0 on that answer. The mod computes `r` from
`MaxPagerAnswers` and the player's own answers (`AnswerPagerCount` minus what
the cap pre-spent), so the display needs no maximum and is exact for `0` too.
The tag is the colour: `DefaultValue` with two or more left, `WarningValue`
with one, `AlertValue` with none - all three seen drawn by the game on a heist
granting 2. There are two live copies of the widget, one per heist-state
screen, and both are corrected.

**Per-heist state** is keyed on the game state object, not on `ClientRestart`:
guards and the HUD exist before that event fires, and the cap must not be
charged twice if it fires again mid-heist.

**Event driven.** No polling loop. Hooks used:

    /Script/Starbreeze.SBZAICharacter:Multicast_ShowAlertedMarker
                                     :Multicast_UpdateSuspiciousMarkers
                                     :Multicast_UpdateSuspiciousMarkerProgress
                                     :Multicast_HideSuspiciousMarker
    /Script/Engine.PlayerController:ClientRestart
    /Script/UMG.RichTextBlock:SetText
    /Game/UI/Widgets/HUD/PlayerAndParty/WBP_UI_PagerWidget.WBP_UI_PagerWidget_C
                                     :UpdatePagerStatus
                                     :GetPagerStatus
                                     :OnAnswerPagerValueChanged
    NotifyOnNewObject("/Script/Starbreeze.SBZAICharacter")

The only enumerations are one `FindAllOf` sweep of guards at heist start, to
catch those that spawned before the hooks were live, and one of the pager
widgets when the cap is applied, to correct their labels.

**Host side only.** Pager arming is server-side. This works solo and when
hosting. As a client in someone else's lobby the host decides, and these local
flags will not stop it.

---

## Known issues

**The HUD counter's colour thresholds come from one heist.** Default, warning
and alert are mapped to two-or-more, one and zero remaining, which is exactly
what a heist granting 2 draws. A heist granting more may switch to warning
earlier than that in stock; if so, the `HUD:` log lines show which tag the
game used for which digit, and `style_for` in the script is the place to fix.

---

## Reading the log

`KaisSilentAssasin.log`, in the mod folder, written when `LogToFile = true`
and rewritten each heist by default.

    --- heist start (<what triggered it>) ---
    silenced / restored / re-silenced <guard>   awareness changes
    MaxPagerAnswers: live max N (<source>)      what this heist actually grants
    MaxPagerAnswers: AnswerPagerCount a -> b    the cap being applied
    HUD: <screen> radios a -> b (<why>)         the counter being corrected
    trace: ...                                  pager diagnostics

`live max N` is the number to check on an unfamiliar heist. Bebe grants 2.

---

## Verified

Confirmed in play, on Bebe (`live max 2`):

- unaware kill → no pager; aware kill → pager
- suspicious-then-forgot → no pager
- `MaxPagerAnswers = 1` → first answer safe, second starts the search
- `MaxPagerAnswers = 0` → first answered pager starts the search
- `-1` → stock behaviour
- `MaxPagerAnswers = 1`, HUD: cap applied at heist start; counter 2 (orange)
  from the start, 1 (red) after the first answer, 0 on the second, which
  started the search; both widget copies corrected, no game overwrite

**Not verified:** other heists (only Bebe has been played),
`ResetOnSuspicionLost = false`, `SuspicionThreshold > 0` (both parsed and wired
but never played), and multiplayer as a client.

---

## After a PAYDAY 3 update

1. Update PD3 UE4SS first — its offsets are tied to a specific game build.
2. Turn on `LogToFile`, launch and check the log for `hooks: ... =true` on
   the first line. A `false`
   means that hook's function was renamed.
3. `could not set bIsPagerSnatched` means the property changed name.
4. On a new heist, check `live max N` against what the HUD shows at the start:
   stock is `N + 1`, with a cap it is `MaxPagerAnswers + 1`. No `HUD:` lines at
   all means the label's text or name changed; wrong digits mean the widget
   contract changed.
