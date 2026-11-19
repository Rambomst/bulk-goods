-- Bulk Goods: Shift-click a vendor item and buy more than one stack in Blizzard's own quantity window.
--
-- Blizzard opens that window (StackSplitFrame) with at most one stack, because one BuyMerchantItem call never buys
-- more. Bulk Goods raises the window's ceiling to the most the bags, the money and the vendor allow, and buys the
-- amount picked one stack per call, each call once the one before has reached the bags. In a raised window the
-- digits typed are the total wanted, even for an item sold several at a time, which Blizzard's window counts in
-- bundles.
--
-- Only stackable items paid for in gold alone, under the price Blizzard asks about (MERCHANT_HIGH_PRICE_COST), get
-- the higher ceiling. Every other vendor item keeps Blizzard's prompt and confirmations as they are.

local TITLE = "Bulk Goods"
-- Seconds a purchase may take to reach the bags before the rest is given up.
local TIMEOUT = 5

local function Print(text)
	DEFAULT_CHAT_FRAME:AddMessage("|cffffd200" .. TITLE .. "|r: " .. text)
end

-------------------------------------------------------------------------------------------------------------------
-- How much can be bought
-------------------------------------------------------------------------------------------------------------------

-- How many more of the item the bags can hold: the empty slots of every bag that takes it, as full stacks, plus
-- what its partial stacks lack.
local function BagRoom(itemID, stackSize)
	local family = C_Item.GetItemFamily(itemID) or 0
	local room = 0
	for bag = BACKPACK_CONTAINER, NUM_BAG_SLOTS do
		local free, bagFamily = C_Container.GetContainerNumFreeSlots(bag)
		-- A special bag (quiver, soul bag) only takes items of its own family.
		if free and (bagFamily == 0 or bit.band(family, bagFamily or 0) ~= 0) then
			room = room + free * stackSize
			for slot = 1, C_Container.GetContainerNumSlots(bag) do
				local item = C_Container.GetContainerItemInfo(bag, slot)
				if item and item.itemID == itemID and item.stackCount < stackSize then
					room = room + stackSize - item.stackCount
				end
			end
		end
	end
	return room
end

-- What buying vendor item `index` past one stack takes, or nil where Blizzard's prompt stays as it is: anything paid
-- for with more than gold, priced at or over MERCHANT_HIGH_PRICE_COST (Blizzard confirms those), or not an item.
local function Plan(index)
	local info = C_MerchantFrame.GetItemInfo(index)
	if not info or not info.isPurchasable or info.hasExtendedCost or info.currencyID then
		return nil
	end
	local price = info.price or 0
	if price <= 0 or price >= (MERCHANT_HIGH_PRICE_COST or 1500000) or GetMerchantItemCostInfo(index) ~= 0 then
		return nil
	end
	local link = GetMerchantItemLink(index)
	local itemID = link and tonumber(link:match("item:(%d+)"))
	if not itemID then
		return nil
	end
	-- The vendor sells `bundle` at a time (five of something for its price), so every amount is whole bundles.
	local bundle = math.max(info.stackCount or 1, 1)
	local perCall = math.max(GetMerchantItemMaxStack(index) or 1, 1)
	perCall = math.max(perCall - perCall % bundle, bundle)
	local stackSize = C_Item.GetItemMaxStackSizeByID(itemID) or perCall
	-- Whole bundles the money covers. Blizzard's sum, money / (price / bundle), can come out a bundle short in floating
	-- point (55 copper at 11 for five: 20, not 25).
	local most = math.floor(GetMoney() / price) * bundle
	most = math.min(most, BagRoom(itemID, stackSize))
	if info.numAvailable and info.numAvailable >= 0 then
		most = math.min(most, info.numAvailable * bundle)
	end
	return {
		index = index,
		link = link,
		itemID = itemID,
		bundle = bundle,
		perCall = perCall,
		most = most - most % bundle,
	}
end

-------------------------------------------------------------------------------------------------------------------
-- Buying, one stack per call
-------------------------------------------------------------------------------------------------------------------

local jobs = {} -- purchases in the order they were asked for; jobs[1] is being bought
local timer
local events = CreateFrame("Frame")

local STOP_ERRORS = {}
for _, key in ipairs({
	"ERR_INV_FULL",
	"ERR_BAG_FULL",
	"ERR_NOT_ENOUGH_MONEY",
	"ERR_ITEM_MAX_COUNT",
	"ERR_VENDOR_SOLD_OUT",
	"ERR_VENDOR_TOO_FAR",
	"ERR_VENDOR_NOT_INTERESTED",
	"ERR_VENDOR_HATES_YOU",
}) do
	if type(_G[key]) == "string" then
		STOP_ERRORS[_G[key]] = true
	end
end

-- Ends the buying: the purchase in progress and every one queued behind it. A reason is printed with how far it got.
local function Finish(reason)
	local job = jobs[1]
	if job and reason then
		Print(string.format("%s: bought %d of %d. %s", job.link, job.got, job.total, reason))
	end
	wipe(jobs)
	if timer then
		timer:Cancel()
		timer = nil
	end
	events:UnregisterAllEvents()
end

local Send

-- Runs on every bag change while a call is out: once the bags hold what it bought, the next call goes.
local function Check()
	local job = jobs[1]
	if not job or not job.out or C_Item.GetItemCount(job.itemID) < job.target then
		return
	end
	job.got = job.got + job.out
	job.out = nil
	if timer then
		timer:Cancel()
		timer = nil
	end
	if job.left > 0 and job.closed then
		return Finish(job.closed)
	elseif job.left <= 0 then
		table.remove(jobs, 1)
	end
	if jobs[1] then
		Send()
	else
		Finish()
	end
end

function Send()
	local job = jobs[1]
	if not MerchantFrame:IsShown() then
		return Finish("The vendor window closed.")
	end
	-- Limited stock selling out moves the rest of the vendor's list up a place.
	if GetMerchantItemLink(job.index) ~= job.link then
		return Finish("The vendor's list changed.")
	end
	local amount = math.min(job.left, job.perCall)
	job.out = amount
	job.left = job.left - amount
	job.target = C_Item.GetItemCount(job.itemID) + amount
	timer = C_Timer.NewTimer(TIMEOUT, function()
		timer = nil
		if C_Item.GetItemCount(job.itemID) >= job.target then
			return Check()
		end
		Finish(job.closed or "The vendor did not answer.")
	end)
	BuyMerchantItem(job.index, amount)
end

local function Buy(plan, amount)
	jobs[#jobs + 1] = {
		index = plan.index,
		link = plan.link,
		itemID = plan.itemID,
		perCall = plan.perCall,
		total = amount,
		left = amount,
		got = 0,
	}
	if #jobs == 1 then
		events:RegisterEvent("BAG_UPDATE")
		events:RegisterEvent("BAG_UPDATE_DELAYED")
		events:RegisterEvent("UI_ERROR_MESSAGE")
		events:RegisterEvent("MERCHANT_CLOSED")
		Send()
	end
end

events:SetScript("OnEvent", function(_, event, _, message)
	local job = jobs[1]
	if not job then
		return
	end
	if event == "UI_ERROR_MESSAGE" then
		if job.out and STOP_ERRORS[message] then
			Finish(message)
		end
	elseif event == "MERCHANT_CLOSED" then
		-- A call already sent still arrives; nothing more goes out.
		for i = #jobs, 2, -1 do
			jobs[i] = nil
		end
		job.closed = "The vendor window closed."
		if not job.out then
			Finish(job.closed)
		end
	else
		Check()
	end
end)

-------------------------------------------------------------------------------------------------------------------
-- The amount typed into a raised prompt
-------------------------------------------------------------------------------------------------------------------

-- Blizzard's prompt reads the digits typed for an item sold five at a time as a number of fives ("8 Stacks, 40
-- Total"), and a leading 0 as a 1. Under its one-stack ceiling that costs a stack at most; under a raised one, 80
-- typed for 80 Mild Spices bought 400. In a raised prompt the digits typed are the total instead, rounded up to whole
-- bundles, and a digit that would take it past the ceiling is dropped, as Blizzard drops it. These post-hooks put the
-- amount right after Blizzard's handlers have run, and write to the prompt only while it is raised.

-- The prompt raised and still open: { prompt, owner = vendor button, most, bundle, split = the amount in it, typed =
-- the number typed so far, nil before the first digit }.
local raised

-- `raised` while that prompt is still the one shown: Blizzard opens the prompt again for bags and banks.
local function Raised()
	local r = raised
	if r and r.prompt:IsShown() and r.prompt.owner == r.owner and r.prompt.maxStack == r.most then
		return r
	end
end

local function Put(r)
	local prompt = r.prompt
	prompt.split = r.split
	prompt:UpdateStackText()
	prompt.LeftButton:SetEnabled(r.split > r.bundle)
	prompt.RightButton:SetEnabled(r.split < r.most)
end

-- Whole bundles for `typed`, one at least.
local function Whole(r, typed)
	return math.max(math.ceil(typed / r.bundle), 1) * r.bundle
end

-- Digits typed after an arrow go on from the amount it left, as in Blizzard's prompt.
local function Stepped(r)
	r.split = r.prompt.split
	if r.typed then
		r.typed = r.split
	end
end

local function OnChar(_, char)
	local r = Raised()
	if not r or not char:match("^%d$") then
		return
	end
	local typed = (r.typed or 0) * 10 + tonumber(char)
	local split = Whole(r, typed)
	if split <= r.most then
		r.typed, r.split = typed, split
	end
	Put(r)
end

local function OnKeyDown(_, key)
	local r = Raised()
	if not r then
		return
	elseif key == "BACKSPACE" or key == "DELETE" then
		if r.typed then
			r.typed = r.typed >= 10 and math.floor(r.typed / 10) or nil
			r.split = r.typed and Whole(r, r.typed) or r.bundle
		end
		Put(r)
	elseif key == "LEFT" or key == "DOWN" or key == "RIGHT" or key == "UP" then
		Stepped(r)
	end
end

local function OnArrowClick()
	local r = Raised()
	if r then
		Stepped(r)
	end
end

-------------------------------------------------------------------------------------------------------------------
-- Blizzard's prompt with a higher ceiling
-------------------------------------------------------------------------------------------------------------------

-- Only the prompt's ceiling and the amount typed into it change; Blizzard opened it, owns it and closes it (page
-- turn, vendor closed). Opening it again from here would make every later use of the prompt run tainted, through its
-- owner field.
local plans = {} -- [vendor button] = the plan of the prompt raised on it
local blizzardSplitStack = {} -- [vendor button] = Blizzard's SplitStack, kept when Bulk Goods first wraps it
local hooked -- whether the prompt's typing is hooked, as it is from the first prompt raised

-- Where the prompt hands the amount picked: past one stack Bulk Goods buys it, the rest stays Blizzard's.
local function SplitStack(button, amount)
	local plan = plans[button]
	plans[button] = nil
	raised = nil
	if plan and amount > plan.perCall and button:GetID() == plan.index then
		Buy(plan, math.min(amount, plan.most))
	else
		blizzardSplitStack[button](button, amount)
	end
end

hooksecurefunc("MerchantItemButton_BuyMultipleStacks", function(button)
	plans[button] = nil
	raised = nil
	-- With the gamepad interface on, the prompt's own handlers run gamepad code that a changed prompt would taint,
	-- and the next protected gamepad call would be blocked.
	if InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled() then
		return
	end
	local prompt = StackSplitFrame
	-- No prompt: an item that does not stack, or none affordable.
	if not prompt:IsShown() or prompt.owner ~= button then
		return
	end
	local plan = Plan(button:GetID())
	if not plan or plan.most <= prompt.maxStack then
		return
	end
	if not blizzardSplitStack[button] then
		blizzardSplitStack[button] = button.SplitStack
		button.SplitStack = SplitStack
	end
	if not hooked then
		hooked = true
		prompt:HookScript("OnChar", OnChar)
		prompt:HookScript("OnKeyDown", OnKeyDown)
		prompt.LeftButton:HookScript("OnClick", OnArrowClick)
		prompt.RightButton:HookScript("OnClick", OnArrowClick)
	end
	plans[button] = plan
	prompt.maxStack = plan.most
	raised = { prompt = prompt, owner = button, most = plan.most, bundle = plan.bundle, split = prompt.split }
end)
