-- A stand-in for a Forever vendor and the player's bags, behind the client's merchant, container and item APIs. A
-- purchase lands in the bags after a latency, as the server's answer does, or fails with the client's red error line.
-- Every BuyMerchantItem call is logged, and one that asks for more than a stack is flagged (the server never sells
-- more than a stack per call).
local Fake = {}
Fake.__index = Fake

-- spec.items: { { itemID, name, price (copper per bundle), stack (max stack), bundle (sold per purchase, 1),
--   available (vendor stock, -1 = unlimited), family (bag family bits, 0), costItems = { { value, link,
--   currencyName } } } }, in vendor order.
-- spec.money: copper.
-- spec.bags: { [bagID] = { size, family = 0, contents = { [slot] = { itemID, count } } } }, bag IDs 0 to 4.
-- spec.latency: seconds until a purchase lands (0.1). spec.silent: purchases never land.
-- spec.failFrom: from this call on, every purchase fails with Inventory is full.
function Fake.install(sim, spec)
	local self = setmetatable({ sim = sim, spec = spec, calls = {}, queue = {}, oversized = {} }, Fake)
	self.latency = spec.latency or 0.1
	self.items = spec.items or {}
	self.bags = spec.bags or { [0] = { size = 16 } }
	for _, bag in pairs(self.bags) do
		bag.contents = bag.contents or {}
	end
	sim.world.player.money = spec.money or 1000000
	local G, impl = sim.G, sim.impl

	local byID = {}
	for _, item in ipairs(self.items) do
		byID[item.itemID] = item
	end
	self.byID = byID

	local function idOf(x)
		if type(x) == "number" then
			return x
		end
		return tonumber(tostring(x):match("item:(%d+)"))
	end
	local function link(itemID)
		local item = byID[itemID]
		return string.format(
			"|cffffffff|Hitem:%d::::::::60:::::::::|h[%s]|h|r",
			itemID,
			item and item.name or ("Item " .. itemID)
		)
	end
	self.link = link

	-- Items.
	impl["C_Item.GetItemInfo"] = function(x)
		local item = byID[idOf(x) or 0]
		if not item then
			return nil
		end
		return item.name, link(item.itemID), 1, 1, 0, "Trade Goods", "Other", item.stack, "", 134400, 1, 7, 0, 0
	end
	G.GetItemInfo = G.C_Item.GetItemInfo
	impl["C_Item.GetItemInfoInstant"] = function(x)
		local item = byID[idOf(x) or 0]
		if item then
			return item.itemID, "Trade Goods", "Other", "", 134400, 7, 0
		end
	end
	impl["C_Item.GetItemQualityByID"] = function(x)
		return byID[idOf(x) or 0] and 1 or nil
	end
	impl["C_Item.GetItemIconByID"] = function()
		return 134400
	end
	impl["C_Item.GetItemNameByID"] = function(x)
		local item = byID[idOf(x) or 0]
		return item and item.name
	end
	impl["C_Item.DoesItemExistByID"] = function(x)
		return byID[idOf(x) or 0] ~= nil
	end
	impl["C_Item.IsItemDataCachedByID"] = impl["C_Item.DoesItemExistByID"]
	impl["C_Item.GetItemFamily"] = function(x)
		local item = byID[idOf(x) or 0]
		return item and (item.family or 0)
	end
	impl["C_Item.GetItemMaxStackSizeByID"] = function(x)
		local item = byID[idOf(x) or 0]
		return item and item.stack
	end

	-- Bags.
	impl["C_Container.GetContainerNumSlots"] = function(bag)
		local b = self.bags[bag]
		return b and b.size or 0
	end
	impl["C_Container.GetContainerNumFreeSlots"] = function(bag)
		local b = self.bags[bag]
		if not b then
			return 0, 0
		end
		local used = 0
		for _ in pairs(b.contents) do
			used = used + 1
		end
		return b.size - used, b.family or 0
	end
	impl["C_Container.GetContainerItemInfo"] = function(bag, slot)
		local b = self.bags[bag]
		local c = b and b.contents[slot]
		if not c then
			return nil
		end
		return {
			itemID = c.itemID,
			stackCount = c.count,
			hyperlink = link(c.itemID),
			iconFileID = 134400,
			quality = 1,
			isLocked = false,
			isReadable = false,
			hasLoot = false,
			hasNoValue = false,
			isFiltered = false,
			isBound = false,
		}
	end
	impl["C_Item.GetItemCount"] = function(x)
		return self:count(idOf(x) or 0)
	end

	-- The vendor.
	G.GetMerchantNumItems = function()
		return #self.items
	end
	impl["C_MerchantFrame.GetItemInfo"] = function(index)
		local item = self.items[index]
		if not item then
			return nil
		end
		return {
			name = item.name,
			texture = 134400,
			price = item.price,
			stackCount = item.bundle or 1,
			numAvailable = item.available or -1,
			isPurchasable = true,
			isUsable = true,
			hasExtendedCost = item.costItems ~= nil,
			isQuestStartItem = false,
		}
	end
	impl["C_MerchantFrame.IsMerchantItemRefundable"] = function()
		return false
	end
	G.GetMerchantItemLink = function(index)
		local item = self.items[index]
		return item and link(item.itemID)
	end
	G.GetMerchantItemID = function(index)
		local item = self.items[index]
		return item and item.itemID
	end
	G.GetMerchantItemMaxStack = function(index)
		local item = self.items[index]
		return item and item.stack or 0
	end
	G.GetMerchantItemCostInfo = function(index)
		local item = self.items[index]
		return item and item.costItems and #item.costItems or 0
	end
	G.GetMerchantItemCostItem = function(index, i)
		local item = self.items[index]
		local cost = item and item.costItems and item.costItems[i]
		if cost then
			return 134400, cost.value, cost.link, cost.currencyName
		end
		-- The client answers a cost slot the item does not have with a zero amount: Blizzard multiplies it.
		return nil, 0, nil, nil
	end
	G.CanAffordMerchantItem = function()
		return true
	end
	-- Natives Blizzard's merchant frame calls that the sim does not define: an empty buyback list, no repairs.
	G.GetNumBuybackItems = function()
		return 0
	end
	G.GetBuybackItemInfo = function() end
	G.GetBuybackItemLink = function() end
	G.CanMerchantRepair = function()
		return false
	end
	G.GetRepairAllCost = function()
		return 0, false
	end
	G.CanGuildBankRepair = function()
		return false
	end
	G.ResetSetMerchantFilter = function() end
	G.SetMerchantFilter = function() end
	G.BuyMerchantItem = function(index, quantity)
		local item = self.items[index]
		local call = {
			index = index,
			quantity = quantity,
			itemID = item and item.itemID,
			taint = sim.taint.current,
			hardware = sim.hardwareInput,
		}
		self.calls[#self.calls + 1] = call
		local n = #self.calls
		if item and quantity > item.stack then
			self.oversized[#self.oversized + 1] = call
		end
		if spec.silent then
			return
		end
		self.queue[#self.queue + 1] = {
			due = sim.time + self.latency,
			f = function()
				self:answer(n, item, quantity)
			end,
		}
	end

	-- Modified clicks: Shift is the split-stack modifier, as in the client's default bindings.
	G.IsModifiedClick = function(action)
		if not sim.modifiers.shift then
			return false
		end
		return action == nil or action == "SPLITSTACK"
	end
	return self
end

function Fake:count(itemID)
	local n = 0
	for _, bag in pairs(self.bags) do
		for _, c in pairs(bag.contents) do
			if c.itemID == itemID then
				n = n + c.count
			end
		end
	end
	return n
end

-- Puts quantity of the item into the bags, partial stacks first, or changes nothing and returns false when it does
-- not all fit.
function Fake:store(itemID, quantity)
	local item = self.byID[itemID]
	local family = item.family or 0
	local plan, left = {}, quantity
	local bagIDs = {}
	for bagID in pairs(self.bags) do
		bagIDs[#bagIDs + 1] = bagID
	end
	table.sort(bagIDs)
	local function takes(bag)
		local bf = bag.family or 0
		return bf == 0 or bit.band(family, bf) ~= 0
	end
	for _, bagID in ipairs(bagIDs) do
		local bag = self.bags[bagID]
		if takes(bag) then
			for slot = 1, bag.size do
				local c = bag.contents[slot]
				if left > 0 and c and c.itemID == itemID and c.count < item.stack then
					local add = math.min(left, item.stack - c.count)
					plan[#plan + 1] = { bag = bagID, slot = slot, add = add }
					left = left - add
				end
			end
		end
	end
	for _, bagID in ipairs(bagIDs) do
		local bag = self.bags[bagID]
		if takes(bag) then
			for slot = 1, bag.size do
				if left > 0 and not bag.contents[slot] then
					local add = math.min(left, item.stack)
					plan[#plan + 1] = { bag = bagID, slot = slot, add = add, new = true }
					left = left - add
				end
			end
		end
	end
	if left > 0 then
		return false
	end
	local touched = {}
	for _, p in ipairs(plan) do
		local bag = self.bags[p.bag]
		if p.new then
			bag.contents[p.slot] = { itemID = itemID, count = p.add }
		else
			bag.contents[p.slot].count = bag.contents[p.slot].count + p.add
		end
		touched[p.bag] = true
	end
	return true, touched
end

function Fake:answer(n, item, quantity)
	local sim, G = self.sim, self.sim.G
	local fail
	local cost = item and math.ceil(item.price * quantity / (item.bundle or 1)) or 0
	if not item then
		fail = G.ERR_VENDOR_NOT_INTERESTED or "Vendor not interested"
	elseif self.spec.failFrom and n >= self.spec.failFrom then
		fail = G.ERR_INV_FULL
	elseif sim.world.player.money < cost then
		fail = G.ERR_NOT_ENOUGH_MONEY
	end
	local touched
	if not fail then
		local ok
		ok, touched = self:store(item.itemID, quantity)
		if not ok then
			fail = G.ERR_INV_FULL
		end
	end
	if fail then
		sim.events.fire("UI_ERROR_MESSAGE", 0, fail)
		return
	end
	sim.world.player.money = sim.world.player.money - cost
	sim.events.fire("PLAYER_MONEY")
	for bagID in pairs(touched) do
		sim.events.fire("BAG_UPDATE", bagID)
	end
	sim.events.fire("BAG_UPDATE_DELAYED")
	sim.events.fire("MERCHANT_UPDATE")
end

-- Advances the client and delivers every answer that falls due, in steps of at most 50 ms.
function Fake:tick(seconds)
	local remaining = seconds or 0.05
	repeat
		local d = math.min(0.05, remaining)
		remaining = remaining - d
		self.sim:advance(d)
		local due, keep = {}, {}
		for _, entry in ipairs(self.queue) do
			if entry.due <= self.sim.time + 1e-9 then
				due[#due + 1] = entry
			else
				keep[#keep + 1] = entry
			end
		end
		self.queue = keep
		for _, entry in ipairs(due) do
			entry.f()
		end
		self.sim.events.flush()
	until remaining <= 1e-9
end

-- The quantities BuyMerchantItem was called with, as "20,10".
function Fake:quantities()
	local out = {}
	for _, call in ipairs(self.calls) do
		out[#out + 1] = tostring(call.quantity)
	end
	return table.concat(out, ",")
end

return Fake
