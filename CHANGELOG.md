# Changelog

## v1.0.2

- Fixed: after Enter, Backspace or an arrow key in a raised window, closing a quantity window later with a key held
  (walking away from the vendor, say) was blocked with "Bulk Goods tried to call the protected function
  RunBinding()", and a held movement key could keep your character moving. Bulk Goods now writes nothing into
  Blizzard's window.
- Blizzard's window now buys its own part, up to one stack, as soon as you click Okay, and Bulk Goods buys the rest.
- The number you type is still how many you get, except a number small enough for Blizzard's window to take whole
  as bundles: 3 alone for an item sold five at a time is three fives, as in Blizzard's window. The window shows it.

## v1.0.1

- For an item the vendor sells several at a time (Mild Spices come five for a price), the number you type is now
  how many you get, rounded up to whole bundles. Blizzard's window counts the bundles, so typing 80 bought 400.
  Backspace and the arrows work on that total too.
- A leading 0 no longer counts as a 1: typing 050 bought 150.
- The most the window offers no longer comes out one bundle short when your gold exactly covers it.

## v1.0.0

First release.

- Shift-click a vendor item and Blizzard's quantity window goes past one stack, up to what your gold, your bags and
  the vendor's stock allow.
- More than a stack is bought a stack at a time, each once the last one is in your bags. If something stops it, a
  chat line says how many arrived and why.
- Items paid for with anything but gold, items at 150 gold or more, and the gamepad interface keep Blizzard's
  one-stack window.
