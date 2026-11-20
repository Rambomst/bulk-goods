-- Bulk Goods: Shift-click a vendor item and buy more than one stack in Blizzard's own quantity window.
--
-- Blizzard opens that window (StackSplitFrame) with at most one stack, because one BuyMerchantItem call never buys
-- more. Bulk Goods lets the amount in it go up to the most the bags, the money and the vendor allow, and buys what is
-- past Blizzard's own amount one stack per call, each call once the one before has reached the bags.
--
-- It writes nothing into the window or the vendor buttons. Secure code that reads a field an addon wrote runs tainted
-- from there on; the window's key handler then records the keys held in a table that only tainted code can write
-- again, and a later close of any quantity window runs the release of a held key (moving, Enter) as a forbidden
-- action. So the window keeps Blizzard's own amount, under Blizzard's one-stack ceiling, and Bulk Goods keeps its
-- own amount and shows it in the window: the digits typed are the total, even for an item sold several at a time,
-- which Blizzard's window counts in bundles.
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
local Check
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

local Next

local function Wait(job)
	if timer then
		timer:Cancel()
	end
	timer = C_Timer.NewTimer(TIMEOUT, function()
		timer = nil
		if C_Item.GetItemCount(job.itemID) >= job.target then
			return Check()
		end
		Finish(job.closed or "The vendor did not answer.")
	end)
end

-- Runs on every bag change while a call is out: once the bags hold what it bought, the next call goes.
function Check()
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
	Next()
end

local function Send()
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
	Wait(job)
	BuyMerchantItem(job.index, amount)
end

function Next()
	local job = jobs[1]
	if not job then
		return Finish()
	elseif job.out then
		-- Blizzard's own call for it went out when its window was confirmed.
		Wait(job)
		return Check()
	end
	Send()
end

-- `total` of the plan's item, of which Blizzard's window has just sent `sent` itself.
local function Buy(plan, total, sent)
	-- Calls already out for the same item land in the same count.
	local pending = 0
	for _, job in ipairs(jobs) do
		if job.itemID == plan.itemID and job.out then
			pending = pending + job.out
		end
	end
	jobs[#jobs + 1] = {
		index = plan.index,
		link = plan.link,
		itemID = plan.itemID,
		perCall = plan.perCall,
		total = total,
		left = total - sent,
		got = 0,
		out = sent,
		target = C_Item.GetItemCount(plan.itemID) + pending + sent,
	}
	if #jobs == 1 then
		events:RegisterEvent("BAG_UPDATE")
		events:RegisterEvent("BAG_UPDATE_DELAYED")
		events:RegisterEvent("UI_ERROR_MESSAGE")
		events:RegisterEvent("MERCHANT_CLOSED")
		Next()
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
-- The amount past Blizzard's ceiling
-------------------------------------------------------------------------------------------------------------------

-- The window raised and still open: { prompt, owner = vendor button, plan, most, step = the bundle, amount = Bulk
-- Goods's own, shown = what the window shows, typed = the number typed so far, nil before the first digit }.
--
-- The digits typed are the total, rounded up to whole bundles, and a digit that would take it past the ceiling is
-- dropped. Blizzard's own amount reads the same digits as bundles ("8 Stacks, 40 Total") and a leading 0 as a 1, but
-- stays under its one-stack ceiling, which drops all but its first digit or two: for 30 Mild Spices (five at a time)
-- it holds three fives. Its Okay buys it, so the window shows whichever is larger: only a number small enough for
-- Blizzard's window to take whole as bundles (3 alone is three fives) shows and buys Blizzard's total.
local raised

-- `raised` while that window is still the one shown: Blizzard opens it again for bags and banks.
local function Raised()
	local r = raised
	if r and not r.closed and r.prompt:IsShown() and r.prompt.owner == r.owner then
		return r
	end
end

-- Shows the amount, after Blizzard's handler has shown its own.
local function Put(r)
	local prompt = r.prompt
	r.shown = math.max(r.amount, prompt.split or 0)
	if prompt.isMultiStack then
		prompt.StackSplitText:SetText(STACKS:format(r.shown / r.step))
		prompt.StackItemCountText:SetText(TOTAL_STACKS:format(r.shown))
	else
		prompt.StackSplitText:SetText(r.shown)
	end
	prompt.LeftButton:SetEnabled(r.shown > r.step)
	prompt.RightButton:SetEnabled(r.shown < r.most)
end

-- Whole bundles for `typed`, one at least.
local function Whole(r, typed)
	return math.max(math.ceil(typed / r.step), 1) * r.step
end

-- The arrows step a bundle from the amount shown; digits typed after them go on from there, as in Blizzard's
-- window, and before any digit the first one starts the total.
local function Step(r, bundles)
	r.amount = math.min(math.max(r.shown + bundles * r.step, r.step), r.most)
	if r.typed then
		r.typed = r.amount
	end
	Put(r)
end

local function OnChar(_, char)
	local r = Raised()
	if not r or not char:match("^%d$") then
		return
	end
	local typed = (r.typed or 0) * 10 + tonumber(char)
	local amount = Whole(r, typed)
	if amount <= r.most then
		r.typed, r.amount = typed, amount
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
			r.amount = r.typed and Whole(r, r.typed) or r.step
		end
		Put(r)
	elseif key == "LEFT" or key == "DOWN" then
		Step(r, -1)
	elseif key == "RIGHT" or key == "UP" then
		Step(r, 1)
	end
end

local function OnLeftClick()
	local r = Raised()
	if r then
		Step(r, -1)
	end
end

local function OnRightClick()
	local r = Raised()
	if r then
		Step(r, 1)
	end
end

-- Closed, not forgotten: Blizzard's Okay hides the window before it calls SplitStack.
local function OnHide()
	if raised then
		raised.closed = true
	end
end

-------------------------------------------------------------------------------------------------------------------
-- Blizzard's prompt with a higher ceiling
-------------------------------------------------------------------------------------------------------------------

local hookedButtons = {} -- vendor buttons whose SplitStack is hooked
local hooked -- whether the window's typing is hooked, as it is from the first window raised

-- Blizzard's Okay closes the window, then hands its own amount to the vendor button's SplitStack, which buys it.
-- This runs after that and buys the rest.
local function AfterSplitStack(button, split)
	local r = raised
	if not r or r.owner ~= button then
		return
	end
	raised = nil
	local total = math.min(math.max(r.amount, split), r.plan.most)
	if total > split and button:GetID() == r.plan.index then
		Buy(r.plan, total, split)
	end
end

hooksecurefunc("MerchantItemButton_BuyMultipleStacks", function(button)
	raised = nil
	-- The gamepad interface moves the window's amount by its own paths, which these hooks do not follow.
	if InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled() then
		return
	end
	local prompt = StackSplitFrame
	-- No prompt: an item that does not stack, or none affordable.
	if not prompt:IsShown() or prompt.owner ~= button then
		return
	end
	local plan = Plan(button:GetID())
	if not plan or plan.most <= (prompt.maxStack or 0) then
		return
	end
	if not hookedButtons[button] then
		hookedButtons[button] = true
		hooksecurefunc(button, "SplitStack", AfterSplitStack)
	end
	if not hooked then
		hooked = true
		prompt:HookScript("OnChar", OnChar)
		prompt:HookScript("OnKeyDown", OnKeyDown)
		prompt:HookScript("OnHide", OnHide)
		prompt.LeftButton:HookScript("OnClick", OnLeftClick)
		prompt.RightButton:HookScript("OnClick", OnRightClick)
	end
	raised = {
		prompt = prompt,
		owner = button,
		plan = plan,
		most = plan.most,
		step = plan.bundle,
		amount = plan.bundle,
	}
	Put(raised)
end)
