-- Scenario tests for Bulk Goods on forever_sim, the headless Forever client from cjber/forever-core, with Blizzard's
-- real merchant frame and quantity prompt (StackSplitFrame) and a fake vendor and bags (fake_vendor.lua). Run with
-- tests/run.sh, which sets FOREVER_SIM and BULKGOODS_SIM_CACHE.
local here = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local SIM = assert(os.getenv("FOREVER_SIM"), "FOREVER_SIM is not set: run tests/run.sh")
local CACHE = assert(os.getenv("BULKGOODS_SIM_CACHE"), "BULKGOODS_SIM_CACHE is not set: run tests/run.sh")
-- The repository root holds the addon's TOC; BULKGOODS_ADDON_DIR runs the scenarios against another copy, such as
-- an installed one.
local ADDON_DIR = os.getenv("BULKGOODS_ADDON_DIR") or (here .. "..")

local Sim = dofile(SIM .. "sim.lua")
local Fake = dofile(here .. "fake_vendor.lua")

local GOLD = 10000

-- Vendor slots (the merchant index of each item).
local SPICES, POUCH, BUNDLE, PRICEY, TOKEN, LIMITED = 1, 2, 3, 4, 5, 6

local function items()
	local list = {
		{ itemID = 2678, name = "Hot Spices", price = 10, stack = 20 },
		{ itemID = 4496, name = "Small Brown Pouch", price = 500, stack = 1 },
		-- Sold five at a time, 50 copper for the five.
		{ itemID = 90001, name = "Test Bundle", price = 50, stack = 20, bundle = 5 },
		{ itemID = 90002, name = "Test Pricey", price = 160 * GOLD, stack = 20 },
		{
			itemID = 90003,
			name = "Test Token Item",
			price = 0,
			stack = 20,
			costItems = { { value = 2, currencyName = "Test Favor" } },
		},
		{ itemID = 90004, name = "Test Limited", price = 100, stack = 20, available = 25 },
	}
	-- Fillers, so the vendor has a second page (ten items a page).
	for i = 1, 6 do
		list[#list + 1] = { itemID = 90100 + i, name = "Test Filler " .. i, price = 10, stack = 20 }
	end
	return list
end

local function bags(free)
	local out = { [0] = { size = free or 16 } }
	for bag = 1, 4 do
		out[bag] = { size = 0 }
	end
	for _, bag in pairs(out) do
		bag.contents = {}
	end
	return out
end

local Session = {}
Session.__index = Session

-- The key bindings the scenarios use.
local BINDINGS = { W = "MOVEFORWARD", ENTER = "OPENCHAT" }

-- The sim's stand-in for the bags' token tracker (scenario.lua ensureBagTracker) lacks ShouldShow, so the bags
-- Blizzard opens with the vendor window fail, and MerchantFrame_OnShow stops before it fills the vendor's items.
-- A tracker with that method, put there first, keeps the sim's from being made.
local function bagTracker(sim)
	local G = sim.G
	local manager = G.ContainerFrameSettingsManager
	if manager and not manager.TokenTracker then
		local tracker = G.CreateFrame("Frame", "BulkGoodsTestTokenTracker", G.UIParent)
		tracker.SetIsCombinedInventory = function() end
		tracker.MarkDirty = function() end
		tracker.ShouldShow = function()
			return false
		end
		manager.TokenTracker = tracker
	end
end

-- A logged-in client at an open vendor. opts.spec replaces parts of the vendor (Fake.install's spec);
-- opts.addon = false runs Blizzard alone.
local function open(opts)
	opts = opts or {}
	local sim = Sim.new({ cache = CACHE })
	sim:loadBlizzard("Blizzard_FrameXML:StackSplitFrame")
	if opts.addon ~= false then
		sim:addon(ADDON_DIR)
	end
	local spec = { money = 10 * GOLD, items = items(), bags = bags() }
	for k, v in pairs(opts.spec or {}) do
		spec[k] = v
	end
	local vendor = Fake.install(sim, spec)
	sim:login()
	local s = setmetatable({ sim = sim, vendor = vendor, G = sim.G }, Session)
	s.bootErrors = sim:takeErrors()
	bagTracker(sim)
	-- The sim's bag windows fail on bags that hold items (container scale and layout are not modelled), and
	-- MerchantFrame_OnShow opens every bag before it fills the vendor's items. Bag windows are not under test.
	sim.G.OpenAllBags = function() end
	sim.G.CloseAllBags = function() end
	-- A client native the sim does not define: the prompt runs a key's binding, and the client refuses it to tainted
	-- code (ADDON_ACTION_FORBIDDEN), so a release that should stop the character moving never arrives.
	s.bindings = {}
	sim.G.RunBinding = function(action, how)
		s.bindings[#s.bindings + 1] = {
			text = tostring(action) .. ":" .. tostring(how),
			secure = sim.G.issecure(),
		}
	end
	sim.G.GetBindingAction = function(key)
		return BINDINGS[key] or ""
	end
	sim:openMerchant()
	vendor:tick(0.1)
	return s
end

function Session:button(i)
	return self.G["MerchantItem" .. i .. "ItemButton"]
end

-- Shift-clicks the vendor item on button i (1 to 10 on the page shown).
function Session:shiftClick(i)
	self.sim.modifiers.shift = true
	self.sim:click(self:button(i), "LeftButton")
	self.sim.modifiers.shift = nil
	self.vendor:tick(0.05)
end

function Session:prompt()
	return self.G.StackSplitFrame
end

-- Types into the quantity prompt as the keyboard does: one OnChar per character.
function Session:type(text)
	local frame = self:prompt()
	for ch in text:gmatch(".") do
		self.sim:input(function()
			self.sim.widgets.dispatch(frame, "OnChar", ch)
		end)
	end
end

-- Presses a key in the quantity prompt. It comes up in the prompt unless the press closed it, as with Enter.
function Session:key(key)
	local frame = self:prompt()
	self.sim:input(function()
		self.sim.widgets.dispatch(frame, "OnKeyDown", key)
	end)
	if frame:IsShown() then
		self.sim:input(function()
			self.sim.widgets.dispatch(frame, "OnKeyUp", key)
		end)
	end
end

-- Presses a key and keeps it held.
function Session:hold(key)
	local frame = self:prompt()
	self.sim:input(function()
		self.sim.widgets.dispatch(frame, "OnKeyDown", key)
	end)
end

function Session:okay()
	self.sim:click(self:prompt().OkayButton)
end

-- The amount the window shows: the total for an item sold several at a time.
function Session:shown()
	local p = self:prompt()
	if p.isMultiStack then
		return tonumber(p.StackItemCountText:GetText():match("%d+"))
	end
	return tonumber(p.StackSplitText:GetText())
end

-- Clears what was typed, then types `text`.
function Session:retype(text)
	for _ = 1, 8 do
		self:key("BACKSPACE")
	end
	self:type(text)
end

-- The bindings run so far, as "MOVEFORWARD:up", each marked if it ran from tainted code.
function Session:ran()
	local out = {}
	for _, b in ipairs(self.bindings) do
		out[#out + 1] = b.text .. (b.secure and "" or " (tainted)")
	end
	return table.concat(out, ",")
end

-- Opens the prompt on item i, types the amount and clicks Okay, then lets the purchases land.
function Session:buy(i, amount, wait)
	self:shiftClick(i)
	self:type(tostring(amount))
	self:okay()
	self.vendor:tick(wait or 2)
end

-- Chat lines so far, colour codes and link markup removed.
function Session:chat()
	local lines = {}
	for _, line in ipairs(self.sim.chat) do
		line = line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H[^|]*|h", ""):gsub("|h", "")
		lines[#lines + 1] = line
	end
	return table.concat(lines, " / ")
end

function Session:addonErrors()
	local out = {}
	for _, list in ipairs({ self.bootErrors or {}, self.sim:takeErrors() }) do
		for _, e in ipairs(list) do
			if e.taint == "BulkGoods" or tostring(e.message):find("BulkGoods", 1, true) then
				out[#out + 1] = e
			else
				self.otherErrors = self.otherErrors or {}
				self.otherErrors[#self.otherErrors + 1] = e
			end
		end
	end
	self.bootErrors = nil
	return out
end

---------------------------------------------------------------------------------------------------------------
-- Runner
---------------------------------------------------------------------------------------------------------------

local tests = {}
local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

local function eq(actual, expected, what)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
	end
end

local function ok(value, what)
	if not value then
		error((what or "expected true") .. " was false", 2)
	end
end

-- Fields of Blizzard's window and vendor buttons that its secure code reads. A field an addon wrote taints whatever
-- secure code reads it.
local PROMPT_FIELDS = { "down", "maxStack", "split", "typing", "minSplit", "owner", "isMultiStack" }
local BUTTON_FIELDS = { "SplitStack", "hasStackSplit" }

local function clean(s)
	local errors = s:addonErrors()
	if #errors > 0 then
		error("Bulk Goods caused errors:\n" .. Sim.describe(errors), 2)
	end
	eq(#s.vendor.oversized, 0, "calls that asked for more than a stack")
	for _, b in ipairs(s.bindings or {}) do
		if not b.secure then
			error("RunBinding(" .. b.text .. ") ran from tainted code; the client refuses it", 2)
		end
	end
	local prompt = s:prompt()
	for _, field in ipairs(PROMPT_FIELDS) do
		local secure, by = s.G.issecurevariable(prompt, field)
		if not secure then
			error("StackSplitFrame." .. field .. " was written by " .. tostring(by), 2)
		end
	end
	for i = 1, 12 do
		local button = s:button(i)
		for _, field in ipairs(BUTTON_FIELDS) do
			local secure, by = s.G.issecurevariable(button, field)
			if not secure then
				error("MerchantItem" .. i .. "ItemButton." .. field .. " was written by " .. tostring(by), 2)
			end
		end
	end
end

-- The highest amount the raised window takes: typing it shows n with the up arrow off, and typing `over` (n + 1 by
-- default) drops its last digit, leaving `shown`.
local function expectCeiling(s, n, typed, over, shown)
	s:retype(typed or tostring(n))
	eq(s:shown(), n, "the ceiling typed")
	ok(not s:prompt().RightButton:IsEnabled(), "up arrow off at the ceiling")
	s:retype(over or tostring(n + 1))
	eq(s:shown(), shown or math.floor(n / 10), "a digit past the ceiling dropped")
end

---------------------------------------------------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------------------------------------------------

test("Blizzard alone: Shift-click offers one stack", function()
	local s = open({ addon = false })
	s:shiftClick(SPICES)
	local p = s:prompt()
	ok(p:IsShown(), "prompt shown")
	eq(p.maxStack, 20, "Blizzard's ceiling")
	eq(p.owner, s:button(SPICES), "owner")
end)

test("Shift-click opens Blizzard's prompt with more than a stack", function()
	local s = open()
	s:shiftClick(SPICES)
	local p = s:prompt()
	ok(p:IsShown(), "prompt shown")
	-- Still Blizzard's prompt: its owner and its own one-stack amount are untouched.
	eq(p.owner, s:button(SPICES), "owner")
	eq(p.maxStack, 20, "Blizzard's own ceiling")
	eq(s:shown(), 1, "starts at")
	eq(p.isMultiStack, false, "single-item layout")
	ok(p.RightButton:IsEnabled(), "up arrow")
	-- 16 empty slots of 20; 10 gold covers 10,000.
	expectCeiling(s, 320)
	clean(s)
end)

-- Blizzard's own amount stops at its ceiling: 30 typed leaves it at 3, which its Okay buys at once.
test("30 Hot Spices: Blizzard's part at once, then the rest a stack per call", function()
	local s = open({ spec = { latency = 0.3 } })
	s:shiftClick(SPICES)
	s:type("30")
	eq(s:shown(), 30, "typed amount")
	eq(s:prompt().split, 3, "Blizzard's own amount")
	s:okay()
	eq(s.vendor:quantities(), "3", "Blizzard's call goes at once")
	s.vendor:tick(0.1)
	eq(s.vendor:quantities(), "3", "the next call waits for it to land")
	s.vendor:tick(1)
	eq(s.vendor:quantities(), "3,20,7", "calls")
	eq(s.vendor:count(2678), 30, "in the bags")
	eq(s.sim.world.player.money, 10 * GOLD - 300, "money")
	eq(s:chat(), "", "chat")
	ok(not s:prompt():IsShown(), "prompt closed")
	clean(s)
end)

test("one stack or less is one call", function()
	local s = open()
	s:buy(SPICES, 15)
	eq(s.vendor:quantities(), "15", "calls")
	eq(s.vendor:count(2678), 15, "in the bags")
	clean(s)
end)

test("a big order goes a stack per call", function()
	local s = open()
	s:buy(SPICES, 95)
	eq(s.vendor:quantities(), "9,20,20,20,20,6", "calls")
	eq(s.vendor:count(2678), 95, "in the bags")
	clean(s)
end)

test("the ceiling is what the bags hold, partial stacks included", function()
	local b = bags(3)
	b[0].contents[1] = { itemID = 2678, count = 5 }
	local s = open({ spec = { bags = b } })
	s:shiftClick(SPICES)
	-- Two empty slots of 20, and 15 more on the stack of 5.
	expectCeiling(s, 55)
	clean(s)
end)

test("a quiver-type bag does not count for other items", function()
	local b = bags(2)
	b[1] = { size = 10, family = 1 }
	local s = open({ spec = { bags = b } })
	s:shiftClick(SPICES)
	expectCeiling(s, 40)
	clean(s)
end)

test("the ceiling is what the money covers", function()
	local s = open({ spec = { money = 250 } })
	s:shiftClick(SPICES)
	expectCeiling(s, 25)
	clean(s)
end)

test("the ceiling is the vendor's stock", function()
	local s = open()
	s:shiftClick(LIMITED)
	expectCeiling(s, 25)
	clean(s)
end)

test("room for one stack or less keeps Blizzard's prompt", function()
	local s = open({ spec = { bags = bags(1) } })
	s:shiftClick(SPICES)
	local p = s:prompt()
	ok(p:IsShown(), "prompt shown")
	eq(p.owner, s:button(SPICES), "Blizzard's owner")
	eq(p.maxStack, 20, "Blizzard's ceiling")
	s:type("20")
	s:okay()
	s.vendor:tick(1)
	eq(s.vendor:quantities(), "20", "calls")
	clean(s)
end)

test("items Blizzard confirms keep Blizzard's prompt", function()
	local s = open({ spec = { money = 5000 * GOLD } })
	s:shiftClick(PRICEY)
	eq(s:prompt().owner, s:button(PRICEY), "150 gold and up: owner")
	s:type("30")
	eq(s:shown(), 3, "150 gold and up: Blizzard's own amount")
	s:shiftClick(TOKEN)
	eq(s:prompt().owner, s:button(TOKEN), "currency-priced: owner")
	s:type("30")
	eq(s:shown(), 3, "currency-priced: Blizzard's own amount")
	clean(s)
end)

test("an item that does not stack gets no prompt, as with Blizzard alone", function()
	local s = open()
	s:shiftClick(POUCH)
	ok(not s:prompt():IsShown(), "no prompt")
	eq(s.vendor:quantities(), "", "calls")
	clean(s)
end)

test("an item sold five at a time is bought in whole fives", function()
	local s = open()
	s:shiftClick(BUNDLE)
	local p = s:prompt()
	eq(p.minSplit, 5, "step")
	eq(p.isMultiStack, true, "bundle layout")
	s:type("35")
	eq(p.StackSplitText:GetText(), s.G.STACKS:format(7), "fives shown")
	eq(p.StackItemCountText:GetText(), "35 Total", "total shown")
	-- Blizzard's own amount kept the 3 as three fives and dropped the 5.
	eq(p.split, 15, "Blizzard's own amount")
	s:okay()
	s.vendor:tick(2)
	eq(s.vendor:quantities(), "15,20", "calls")
	eq(s.vendor:count(90001), 35, "in the bags")
	eq(s.sim.world.player.money, 10 * GOLD - 350, "money")
	clean(s)
end)

-- Blizzard's window reads the digits as a number of fives: 80 typed was 400 with room for 400, and 40 without (its
-- 0 dropped, "8 Stacks, 40 Total").
test("80 typed for an item sold five at a time buys 80", function()
	for _, free in ipairs({ 22, 16 }) do
		local s = open({ spec = { bags = bags(free) } })
		s:shiftClick(BUNDLE)
		local p = s:prompt()
		s:type("80")
		eq(s:shown(), 80, "typed amount")
		eq(p.StackItemCountText:GetText(), "80 Total", "total shown")
		s:okay()
		s.vendor:tick(2)
		eq(s.vendor:quantities(), "5,20,20,20,15", "calls")
		eq(s.vendor:count(90001), 80, "in the bags")
		clean(s)
	end
end)

-- Patrick's check of 2026-11-20 (Mild Spices, five at a time): 30 showed "30 Stacks, 150 Total" in a build that
-- counted the digits as fives.
test("30 typed for an item sold five at a time buys 30", function()
	local s = open()
	s:shiftClick(BUNDLE)
	local p = s:prompt()
	s:type("30")
	eq(p.StackSplitText:GetText(), s.G.STACKS:format(6), "fives shown")
	eq(p.StackItemCountText:GetText(), "30 Total", "total shown")
	s:okay()
	s.vendor:tick(2)
	eq(s.vendor:quantities(), "15,15", "calls")
	eq(s.vendor:count(90001), 30, "in the bags")
	clean(s)
end)

-- The one case where Blizzard's own amount is above the total typed: a number small enough for Blizzard's window to
-- take whole as fives. Its Okay buys that, so the window shows it.
test("3 alone for an item sold five at a time shows and buys Blizzard's three fives", function()
	local s = open()
	s:shiftClick(BUNDLE)
	s:type("3")
	eq(s:shown(), 15, "Blizzard's total")
	s:okay()
	s.vendor:tick(1)
	eq(s.vendor:quantities(), "15", "calls")
	eq(s.vendor:count(90001), 15, "in the bags")
	clean(s)
end)

test("a total between whole fives is rounded up to the next five", function()
	local s = open()
	s:shiftClick(BUNDLE)
	local p = s:prompt()
	s:type("8")
	eq(s:shown(), 10, "8 typed")
	s:type("3")
	eq(s:shown(), 85, "83 typed")
	eq(p.StackItemCountText:GetText(), "85 Total", "total shown")
	clean(s)
end)

test("a digit that takes the total past the ceiling is dropped", function()
	local s = open({ spec = { bags = bags(3) } })
	s:shiftClick(BUNDLE)
	local p = s:prompt()
	-- 60 fits.
	s:type("80")
	eq(s:shown(), 10, "80 typed: the 0 dropped")
	ok(p.RightButton:IsEnabled(), "up arrow")
	s:key("BACKSPACE")
	s:type("58")
	eq(s:shown(), 60, "58 typed")
	ok(not p.RightButton:IsEnabled(), "up arrow at the ceiling")
	clean(s)
end)

test("Backspace takes the last digit typed off the total", function()
	local s = open()
	s:shiftClick(SPICES)
	s:type("123")
	eq(s:shown(), 123, "123 typed")
	s:key("BACKSPACE")
	eq(s:shown(), 12, "12 left")
	s:shiftClick(BUNDLE)
	local p = s:prompt()
	s:type("123")
	eq(s:shown(), 125, "123 typed")
	s:key("BACKSPACE")
	eq(s:shown(), 15, "12 left")
	eq(p.StackItemCountText:GetText(), "15 Total", "total shown")
	s:key("BACKSPACE")
	eq(s:shown(), 5, "1 left")
	s:key("BACKSPACE")
	eq(s:shown(), 5, "nothing left")
	ok(not p.LeftButton:IsEnabled(), "down arrow at one five")
	s:type("4")
	eq(s:shown(), 5, "typing starts again")
	clean(s)
end)

test("the arrows step a five, and digits typed after them go on from there", function()
	local s = open()
	s:shiftClick(BUNDLE)
	local p = s:prompt()
	s.sim:click(p.RightButton)
	eq(s:shown(), 10, "up arrow")
	-- Before any digit, as in Blizzard's prompt, the first one starts the total.
	s:type("1")
	eq(s:shown(), 5, "1 typed")
	s.sim:click(p.RightButton)
	eq(s:shown(), 10, "up arrow again")
	s:type("5")
	eq(s:shown(), 105, "5 typed after it")
	s:key("LEFT")
	eq(s:shown(), 100, "left arrow key")
	s:key("BACKSPACE")
	eq(s:shown(), 10, "Backspace after it")
	s:okay()
	s.vendor:tick(1)
	eq(s.vendor:quantities(), "5,5", "calls")
	eq(s.vendor:count(90001), 10, "in the bags")
	clean(s)
end)

-- Blizzard's prompt turns a leading 0 into a 1: 050 is 150 there.
test("a leading 0 typed is not a 1", function()
	local s = open()
	s:shiftClick(SPICES)
	s:type("050")
	eq(s:shown(), 50, "050 typed")
	s:okay()
	s.vendor:tick(2)
	eq(s.vendor:quantities(), "15,20,15", "calls")
	eq(s.vendor:count(2678), 50, "in the bags")
	clean(s)
end)

test("an item sold five at a time with room for one stack keeps Blizzard's prompt", function()
	local s = open({ spec = { bags = bags(1) } })
	s:shiftClick(BUNDLE)
	local p = s:prompt()
	eq(p.maxStack, 20, "Blizzard's ceiling")
	s:type("3")
	eq(p.split, 15, "Blizzard's count of fives")
	clean(s)
end)

test("the ceiling for an item sold five at a time is every five the money covers", function()
	-- 11 copper for five, and 66 copper: six fives. Blizzard's sum makes it five.
	local list = items()
	list[BUNDLE].price = 11
	local s = open({ spec = { items = list, money = 66 } })
	s:shiftClick(BUNDLE)
	-- 31 would be 35; the window keeps the 3, which Blizzard's own amount holds as three fives.
	expectCeiling(s, 30, "30", "31", 15)
	clean(s)
end)

test("a full bag mid-order stops the rest and says how far it got", function()
	local s = open({ spec = { failFrom = 2 } })
	s:buy(SPICES, 50)
	eq(s.vendor:quantities(), "5,20", "calls")
	eq(s.vendor:count(2678), 5, "in the bags")
	eq(s:chat(), "Bulk Goods: [Hot Spices]: bought 5 of 50. Inventory is full.", "chat")
	clean(s)
end)

test("closing the vendor mid-order lets the call out land, then stops", function()
	local s = open()
	s:shiftClick(SPICES)
	s:type("50")
	s:okay()
	s.sim:closeMerchant()
	s.vendor:tick(2)
	eq(s.vendor:quantities(), "5", "calls")
	eq(s.vendor:count(2678), 5, "in the bags")
	eq(s:chat(), "Bulk Goods: [Hot Spices]: bought 5 of 50. The vendor window closed.", "chat")
	clean(s)
end)

test("no answer from the vendor gives up after five seconds", function()
	local s = open({ spec = { silent = true } })
	s:buy(SPICES, 30, 4)
	eq(s:chat(), "", "chat before five seconds")
	s.vendor:tick(2)
	eq(s.vendor:quantities(), "3", "calls")
	eq(s:chat(), "Bulk Goods: [Hot Spices]: bought 0 of 30. The vendor did not answer.", "chat")
	clean(s)
end)

test("the vendor's list moving stops the rest", function()
	local s = open()
	s:shiftClick(SPICES)
	s:type("50")
	s:okay()
	-- Something above sells out while the first call is out: the next item moves into slot 1. The call already
	-- sent still lands; nothing more goes to what is now another item.
	table.remove(s.vendor.items, 1)
	s.vendor:tick(2)
	eq(s.vendor:quantities(), "5", "calls")
	eq(s:chat(), "Bulk Goods: [Hot Spices]: bought 5 of 50. The vendor's list changed.", "chat")
	clean(s)
end)

test("turning the page closes the prompt", function()
	local s = open()
	s:shiftClick(SPICES)
	ok(s:prompt():IsShown(), "prompt shown")
	s.sim:click(s.G.MerchantNextPageButton)
	s.vendor:tick(0.1)
	ok(not s:prompt():IsShown(), "prompt closed")
	clean(s)
end)

test("closing the vendor closes the prompt", function()
	local s = open()
	s:shiftClick(SPICES)
	ok(s:prompt():IsShown(), "prompt shown")
	s.sim:closeMerchant()
	ok(not s:prompt():IsShown(), "prompt closed")
	clean(s)
end)

test("Cancel buys nothing", function()
	local s = open()
	s:shiftClick(SPICES)
	s:type("30")
	s.sim:click(s:prompt().CancelButton)
	s.vendor:tick(1)
	eq(s.vendor:quantities(), "", "calls")
	clean(s)
end)

-- Blizzard's own call for each order goes when its Okay is clicked; Bulk Goods's calls go one at a time.
test("the next purchase waits for the one before", function()
	local s = open({ spec = { latency = 0.3 } })
	s:shiftClick(SPICES)
	s:type("30")
	s:okay()
	s:shiftClick(LIMITED)
	s:type("22")
	s:okay()
	s.vendor:tick(3)
	eq(s.vendor:quantities(), "3,2,20,7,20", "calls")
	eq(s.vendor:count(2678), 30, "spices")
	eq(s.vendor:count(90004), 22, "limited")
	clean(s)
end)

test("Shift-click with the chat box open still links the item", function()
	local s = open()
	local linked
	s.G.HandleModifiedItemClick = function(link)
		linked = link
		return true
	end
	s:shiftClick(SPICES)
	ok(linked ~= nil, "link handed to chat")
	ok(not s:prompt():IsShown(), "no prompt")
	clean(s)
end)

test("bag splits still work after a bulk purchase, in and out of combat", function()
	local s = open()
	s:buy(SPICES, 30)
	s.sim:closeMerchant()
	s.sim:enterCombat()
	s.sim:event("PLAYER_TARGET_CHANGED")
	s.sim:leaveCombat()
	clean(s)
end)

test("every surface, gamepad interface off and on, across a reload", function()
	-- The sim's own client, without the fake vendor: every Blizzard surface with Bulk Goods's hooks in place.
	local sim = Sim.new({ cache = CACHE })
	sim:loadBlizzard("Blizzard_FrameXML:StackSplitFrame")
	sim:addon(ADDON_DIR)
	sim:exercise()
end)

test("gamepad interface: Blizzard's prompt stays as it is", function()
	local s = open()
	s.sim:setGamepad(true)
	s:shiftClick(SPICES)
	eq(s:prompt().maxStack, 20, "Blizzard's ceiling")
	s:type("20")
	s:okay()
	s.vendor:tick(1)
	eq(s.vendor:quantities(), "20", "calls")
	s.sim:event("PLAYER_TARGET_CHANGED")
	s.sim:bindingSetChange()
	clean(s)
	s.sim:expectNoGamepadTaint("BulkGoods")
end)

-- The in-game bug of 2026-11-19 (Bulk Goods 1.0.1): a key the raised window handled ran Blizzard's key handler
-- tainted, which wrote its table of held keys from then on; closing the vendor later with a key held ran that key's
-- release through it, and the client refused it (ADDON_ACTION_FORBIDDEN: RunBinding), so a held W kept walking.
for _, how in ipairs({ "ENTER", "BACKSPACE", "DELETE", "LEFT", "RIGHT", "UP", "DOWN", "digits", "arrows" }) do
	test("after " .. how .. " in a raised window, keys held at a close are still released", function()
		local s = open()
		s:shiftClick(SPICES)
		s:type("30")
		if how == "arrows" then
			s.sim:click(s:prompt().RightButton)
			s.sim:click(s:prompt().LeftButton)
		elseif how ~= "digits" then
			s:key(how)
		end
		if s:prompt():IsShown() then
			s:okay()
		end
		s.vendor:tick(2)
		-- Blizzard's own window (a currency-priced item), then the vendor closed while W is held: walking away.
		s:shiftClick(TOKEN)
		s:hold("W")
		s.sim:closeMerchant()
		ok(s:ran():find("MOVEFORWARD:up", 1, true), "W released: " .. s:ran())
		clean(s)
	end)
end

test("walking away from a raised window with W held releases W", function()
	local s = open()
	s:shiftClick(SPICES)
	s:type("40")
	s:key("BACKSPACE")
	s:hold("W")
	s.sim:closeMerchant()
	ok(s:ran():find("MOVEFORWARD:up", 1, true), "W released: " .. s:ran())
	eq(s.vendor:quantities(), "", "nothing bought")
	clean(s)
end)

---------------------------------------------------------------------------------------------------------------

local filter = arg[1]
local passed, failed = 0, 0
for _, t in ipairs(tests) do
	if not filter or t.name:find(filter, 1, true) then
		local okRun, err = pcall(t.fn)
		if okRun then
			passed = passed + 1
			print("ok   " .. t.name)
		else
			failed = failed + 1
			print("FAIL " .. t.name .. "\n     " .. tostring(err):gsub("\n", "\n     "))
		end
	end
end
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
