# Complichess

שחמט עם דק שאתה בונה. **לשחק:** https://complichess-app.github.io/complichess/

Chess where each player builds their own back rank from a 35-point deck of classic,
fairy and original pieces (rope, gun, gravity…). Play on one device, online with a
friend by room code, or against the built-in engine.

**Brainmaxing Chess** mode: the game invents the pieces — seven numbered discs (random1–random7)
with random move maps and rare powers (jump, extra life, shooting, gravity, side-wrap), and pawns
drawn from fairy-chess pawn types. Both players get the same army.

## Store

Complichess Plus (one-time: no ads, ×2 coins, Plus-only skins and board) and coin packs, tied to the player's account.
Payments: Grow (Israel: Bit, Apple Pay, Google Pay, cards) and Paddle (international), or purchase requests approved
on [admin.html](admin.html) until a provider is connected. Terms, refunds, privacy and accessibility: [legal.html](legal.html).
Server: `supabase/store.sql` and the edge functions in `supabase/functions/`. Setup steps: [GO-LIVE.md](GO-LIVE.md).

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
