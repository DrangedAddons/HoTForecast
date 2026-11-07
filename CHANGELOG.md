# Changelog

## 0.9.4
- HoTs on pets in combat. The game hides the target's name when you cast on a pet in combat, so the HoT was dropped. Now HoTForecast takes the frame under your mouse when you cast (click-casting, mouseover macros), or the pet you have targeted.

## 0.9.3
- The last 10 HoT casts and what the game showed about the target and pets are saved, for bug reports.

## 0.9.2
- `/hotf debug` shows what happened to your last HoT cast, and what HoTForecast can read about your target (name, GUID, buffs).

## 0.9.1
- HoTs cast on pets are tracked. The cast's target was only looked up among players, so pet frames showed direct heals but no HoTs.
- A cast's target is matched against your target, focus and mouseover first, then the group and pets.

## 0.9.0
- HoT bars on every pet frame: EllesmereUI's pet frame, its raid-frame pets (pet header and Beside Owner), and WebbyFrames' party pet minis and raid-style pet tiles. WebbyFrames' main pet frame already had them.
- Direct heals on pets: pet frames without an incoming-heal bar of their own get one from HoTForecast, in green, before the HoT bars. "Direct heals on pets" in the settings turns it off.
- The Pet toggle under Show on is now Pets and covers all of them.

## 0.8.0
- Show HoTs from: Everyone, or Only you. With Only you, other HoTForecast users' HoTs are hidden but still tracked, so switching back shows them straight away. `/hotf show mine|all` does the same from chat.
- "Send your HoTs to the group" now only controls sending. Turning it off no longer hides other users' HoTs; use Show HoTs from for that.

## 0.7.0
- Settings window: `/hotf`, the minimap button, the addon compartment, or Options > AddOns > HoTForecast. Everything the slash commands did is there, plus Test bars and Reset all.
- Show on: switch the bars on or off for party and raid frames, player, target, target of target, focus, focus target and pet. Each covers both EllesmereUI and WebbyFrames.
- EllesmereUI unit frames (player, target, target of target, focus, focus target, pet) show the bars too. If EllesmereUI's own heal prediction is off on a frame, the HoT bars start right at the health edge.
- New icon, also used for the minimap button.

## 0.6.1
- EllesmereUI party frames with Show Self First (or Last) on: your own frame now shows HoTs. It's a separate button that wasn't being picked up.

## 0.6.0
- HoTs are shared between HoTForecast users in your group. Other healers' HoTs join your bars and are timed and flashed like your own. `/hotf share on|off` toggles it, and `/hotf debug` shows what was sent and received.

## 0.5.1
- The tick flash plays on every frame showing that player. Before, it played on only one of them, often not the one you were watching.

## 0.5.0
- WebbyFrames support: player, target, target of target, focus, focus target, pet, party frames and the raid-style party tiles.
- EllesmereUI is no longer required. HoTForecast works with either addon, or both.

## 0.4.3
- The tick flash covers the space the tick heals into. It no longer covers health the target already had, which looked like a health loss.

## 0.4.2
- Ticks follow the real heal more closely. Health regen no longer moves the tick on early.
- The last tick of a HoT flashes too.

## 0.4.1
- `/hotf trace` records tick timing for bug reports.

## 0.4.0
- The next tick waits for the real heal. The health rises into it, then the next tick starts from the new edge.
- A short flash when a tick lands. `/hotf flash` toggles it.

## 0.3.0
- Works with any class's HoTs, read from your spell descriptions.

## 0.2.0
- The next tick is a brighter segment ahead of the rest of the HoT. `/hotf tickalpha` sets its opacity.

## 0.1.0
- First version: a faint bar after the incoming-heal prediction on EllesmereUI raid frames, showing what your HoTs will still heal.
