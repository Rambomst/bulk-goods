# Bulk Goods

Shift-click a vendor item to buy more than one stack in one go, in Blizzard's own quantity window. For World of
Warcraft: Forever.

Shift-clicking a vendor item opens Blizzard's quantity window, but it stops at one stack, so 30 Hot Spices take two
trips through it. Bulk Goods lifts that limit and changes nothing else: Shift-click, type 30, Okay, and all 30
arrive.

- **As many as you can buy:** the window goes up to what your gold, your bag space and the vendor's stock allow.
- **A stack at a time:** the vendor still sells one stack per purchase, so Bulk Goods buys the stacks one after
  another, each once the last one is in your bags.
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
- **Buying, one stack per call** (`Buy`, `Send`, `Check`, `Finish`): a queue of purchases. The next
  `BuyMerchantItem` call goes once the item count in the bags has risen by the last one. The buying stops on the
  vendor's errors (`UI_ERROR_MESSAGE`), when the vendor window closes, when the vendor's list moves under it (limited
  stock selling out), or after 5 seconds without an answer.
- **Blizzard's window with a higher ceiling**: a `hooksecurefunc` hook on `MerchantItemButton_BuyMultipleStacks`.

The rules it is built on:

- Blizzard opens `StackSplitFrame` with `GetMerchantItemMaxStack` as its ceiling, because one `BuyMerchantItem` call
  never buys more than that. Nothing else in the window limits the amount.
- So Bulk Goods raises the open window's `maxStack` in place. Opening the window again from addon code would write
  its `owner` field, and every later use of the window (bags, bank, vendor) would run tainted for the session.
- The window's Okay hands the amount to the vendor button's `SplitStack`. Bulk Goods wraps that function on a button
  the first time it raises a window on it; one stack or less still goes to Blizzard's.
- With the gamepad interface on, the window's own handlers run gamepad code, which a raised window would taint, and
  the next protected gamepad call would be blocked. So Bulk Goods leaves the window alone there.
- One known leftover: after a raised window is confirmed with Enter or used with the arrow keys, Blizzard's record
  of the held key is written by tainted code (the window hides before the key comes up). The next close of any
  quantity window runs that key's release binding tainted, which does no harm with mouse and keyboard. With the
  gamepad interface turned on later in the same session, that close would run gamepad code tainted; `/reload`
  clears it.

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

CI runs the tests on every push and pull request.

### In game

Copy or link this repository into `Interface/AddOns` as `BulkGoods` (the folder name has to match the TOC's), then
restart the game, which only looks for new addon folders at startup. After that, `/reload` loads your changes.

## License

MIT
