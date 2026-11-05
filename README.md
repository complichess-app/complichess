# Complichess

שחמט עם דק שאתה בונה. **לשחק:** https://complichess-app.github.io/complichess/

Chess with arenas and pieces to collect. Each player builds their own back rank from a 35-point deck of
classic, fairy and original pieces (rope, gun, gravity…). Every arena unlocks new pieces, and pieces from
higher arenas can be bought with coins: the further the arena, the higher the price. Wins give chests.
Play the arena guardians, a friend online by room code, or on one device.

**Brainmaxing Chess** mode: the game invents the pieces — seven numbered discs (random1–random7)
with random move maps and rare powers (jump, extra life, shooting, gravity, side-wrap), and pawns
drawn from fairy-chess pawn types. Both players get the same army.

## Store

Complichess Plus (one-time: no ads, ×2 coins, faster chests, Plus-only skins and board) and coin packs, tied to the
player's account. They are sold through the Barusik checkout at barusik.com/pay and managed at barusik.com/admin.
Terms, refunds, privacy and accessibility: [legal.html](legal.html). How it fits together: [GO-LIVE.md](GO-LIVE.md).

© 2026 Bar Lvovski — all rights reserved. See [LICENSE](LICENSE).
Contact: complichess.app@gmail.com

## Updates without reinstalling

The game is a web app with a service worker (`sw.js`). Every launch asks the server first, so
players always get the newest version; the cached copy is used only offline. While the game is
open it checks `version.json` and shows an update bar between games.

To ship an update:

```
node tools/release.mjs 2.2.0 "מה חדש"
git commit -am "v2.2.0" && git push
```
