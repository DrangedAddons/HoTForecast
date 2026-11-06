# HoTForecast

A WoW Forever addon that shows how much your HoTs will still heal, right on your raid and party frames.

After the usual incoming-heal bar it draws:

- **the next tick**, a brighter segment
- **the rest of the HoT**, a fainter segment after it

When a tick lands, the health rises into the bright segment, the chunk that was healed flashes, and the next tick starts from the new edge.

Works with **EllesmereUI** raid and party frames and with **WebbyFrames** (player, target, target of target, focus, focus target, pet, party frames and the raid-style party tiles). You need at least one of the two.

## Which HoTs

Any class's HoTs. HoTForecast reads your spell descriptions ("Heals the target for 298 over 15 sec"), so it follows your gear and spell power without a spell list. Bandages, food and damage-over-time spells are skipped. Party-wide heals with no single target, like Tranquility, aren't tracked.

## Other healers

Every HoTForecast user shares their HoTs with the group over addon messages, so you see the HoTs of other healers who run it too. Healers without the addon don't show. On WoW Forever, addons can't read other players' buffs during combat.

## Limits

- In combat the game hides buffs from addons, so HoTs are timed from the cast. A HoT dispelled in combat keeps showing until it would have run out or the fight ends.
- The forecast counts whole ticks at the listed amount. Overhealing is cut off at full health.

## Commands

`/hotf` (or `/hotforecast`):

| Command | What it does |
|---|---|
| `/hotf on` / `off` / `toggle` | Show or hide the bars |
| `/hotf alpha 0-100` | Opacity of the rest-of-HoT bar (default 35) |
| `/hotf tickalpha 0-100` | Opacity of the next-tick bar (default 65) |
| `/hotf color r g b` | Bar colour, 0-1 or 0-255 |
| `/hotf flash on` / `off` | The flash when a tick lands |
| `/hotf share on` / `off` | Send your HoTs to the group and show other users' |
| `/hotf test` | Preview bars and the flash on every frame |
| `/hotf debug` | Attached frames, active HoTs, recognised HoT spells, sharing counters |
| `/hotf trace` / `trace clear` | Record tick timing to the saved variables, for bug reports |

Settings are saved per character.
