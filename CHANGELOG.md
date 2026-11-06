# Changelog

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
