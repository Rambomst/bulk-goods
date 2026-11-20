# Bulk Goods

Shift-click a vendor item to buy more than one stack in one go, in Blizzard's own quantity window. For World of
Warcraft: Forever.

Shift-clicking a vendor item opens Blizzard's quantity window, but it stops at one stack, so 30 Hot Spices take two
trips through it. Bulk Goods lifts that limit in the same window: Shift-click, type 30, Okay, and all 30 arrive.

- **As many as you can buy:** the window goes up to what your gold, your bag space and the vendor's stock allow.
- **The number you type is how many you get:** for an item the vendor sells several at a time (Mild Spices come
  five for a price), it is rounded up to whole bundles. Blizzard's window counts the bundles instead, so typing 80
  there would buy 400. One exception: a number small enough for Blizzard's window to take whole as bundles (3
  alone is three fives) still buys that, and the window shows it.
- **A stack at a time:** the vendor sells at most one stack per purchase, so the rest arrives in more purchases, each
  once the last one is in your bags.
- **A chat line if it stops early:** full bags, not enough gold, the item sold out or the vendor window closed, with
  how many arrived.
- **One stack or less** is bought by Blizzard's window, as always.

Blizzard's one-stack window stays as it is for items paid for with anything but gold (currencies, tokens, other
items), for items at 150 gold or more (Blizzard asks you to confirm those), and while the gamepad interface is on.

There are no settings and no slash command, and nothing is saved. Use it instead of another vendor bulk-buy addon,
not alongside one: they change the same window.

## Install

Install it from [CurseForge](https://www.curseforge.com/wow/addons/bulk-goods) or
[Wago Addons](https://addons.wago.io/addons/bulk-goods), by hand or with an addon manager, or extract the zip from
the newest [release](https://github.com/Rambomst/bulk-goods/releases) into
`World of Warcraft/_forever_/Interface/AddOns`.

## Bugs and ideas

Report them as an [issue](https://github.com/Rambomst/bulk-goods/issues). If a purchase stopped early, include the
chat line it left.

## Support

If Bulk Goods saves you a few trips to the vendor and you'd like to say thanks, you can
[buy me a coffee on Ko-fi](https://ko-fi.com/ram01). It's free either way.

## Development

Everything the addon runs is in `BulkGoods.lua`:

- **How much can be bought** (`Plan`, `BagRoom`): the most the gold, the bags and the vendor's stock allow. Bag room
  counts the free slots of every bag that takes the item, plus the room left on its partial stacks. Items sold
  several at a time (five for a price) are bought in whole bundles.
- **The amount past Blizzard's ceiling** (`OnChar`, `OnKeyDown`, `OnLeftClick`, `OnRightClick`, `Put`): the
  digits typed are the total, rounded up to whole bundles, and Backspace and the arrows work on it; the window shows
  it.
- **Buying, one stack per call** (`Buy`, `Next`, `Send`, `Check`, `Finish`): a queue of purchases, each starting
  with the call Blizzard's window made itself. The next `BuyMerchantItem` call goes once the item count in the bags
  has risen by the last one. The buying stops on the
  vendor's errors (`UI_ERROR_MESSAGE`), when the vendor window closes, when the vendor's list moves under it (limited
  stock selling out), or after 5 seconds without an answer.
- **Blizzard's window with a higher ceiling** (`AfterSplitStack`): `hooksecurefunc` hooks on
  `MerchantItemButton_BuyMultipleStacks` and on each vendor button's `SplitStack`.

The rules it is built on:

- Blizzard opens `StackSplitFrame` with `GetMerchantItemMaxStack` as its ceiling, because one `BuyMerchantItem` call
  never buys more than that. Nothing else in the window limits the amount.
- Bulk Goods writes no field of the window or of the vendor buttons. Secure code that reads a field an addon wrote
  runs tainted from there on. The window's `OnKeyDown` rewrites its table of held keys (`down`) on every key, so once
  a tainted run writes it, it stays tainted for the session, and the next close of any quantity window with a key in
  it runs that key's release through `RunBinding`, which the client refuses to tainted code (ADDON_ACTION_FORBIDDEN):
  a held movement key is never released. 1.0.0 and 1.0.1 raised `maxStack`, wrote `split` and wrapped the button's
  `SplitStack`, and hit this in game.
- So the window keeps Blizzard's own amount (`split`, one stack at most). The first time Bulk Goods raises a window,
  it hooks the window's `OnChar`, `OnKeyDown` and `OnHide` and its arrows' `OnClick` with `HookScript`, so
  Blizzard's handlers still run first and untouched. It keeps its own amount and shows it with `SetText` and
  `SetEnabled` on the window's own text and arrows, which write no Lua field.
- Blizzard's Okay closes the window and hands Blizzard's own amount to the vendor button's `SplitStack`, which buys
  it at once. A `hooksecurefunc` post-hook on that `SplitStack` queues the rest.
- Blizzard's window reads the digits typed for an item sold several at a time as a count of bundles ("8 Stacks, 40
  Total"), and a leading 0 as a 1, but its one-stack ceiling drops every digit that would pass it: for 30 Mild
  Spices (five at a time) its own amount is three fives, which its Okay buys before Bulk Goods buys the other 15.
  The window shows whichever amount is larger, so what is shown is what is bought; Blizzard's is larger only for a
  number small enough for its window to take whole as bundles (3 alone).
- With the gamepad interface on, the window's D-pad calls Blizzard's arrow functions directly, past these hooks, so
  Bulk Goods leaves the window alone there.

Lua is formatted with [StyLua](https://github.com/JohnnyMorganz/StyLua): run `stylua .`, which reads `.stylua.toml`.

### Tests

The tests run the addon on forever_sim, the headless Forever client from
[forever-core](https://github.com/cjber/forever-core), with Blizzard's real merchant frame and quantity window and a
stand-in for the vendor and the bags (`tests/fake_vendor.lua`). They need LuaJIT, Python 3 and git:

```bash
tests/run.sh
```

The first run downloads forever_sim at the commit pinned in `tests/forever_sim.txt`, and the Blizzard UI source and
client data it runs against, into `~/.cache/bulkgoods-sim`.

- `tests/run.sh "ceiling"` runs only the scenarios whose names contain that text.
- `FOREVER_SIM` points the tests at another forever_sim folder, such as the one in a forever-core checkout
  (`.agents/skills/wow-forever-addon/tooling/forever_sim`).
- `BULKGOODS_ADDON_DIR` runs the scenarios against another copy of the addon, such as an installed one.

Every scenario also checks that Bulk Goods wrote no field of the window or the vendor buttons
(`issecurevariable`), and that every key release the window ran (`RunBinding`) ran from secure code.

CI runs the tests on every push and pull request.

### In game

Copy or link this repository into `Interface/AddOns` as `BulkGoods` (the folder name has to match the TOC's), then
restart the game, which only looks for new addon folders at startup. After that, `/reload` loads your changes.

## License

MIT
