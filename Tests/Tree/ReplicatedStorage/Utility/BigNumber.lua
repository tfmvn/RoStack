--!strict
--!native
--[[
	BigNumber
	=========
	Arbitrary-precision decimal-string arithmetic.

	Phase 2.1: the entire economy is string-backed. There are no
	Lua `number` values stored on the persistence record and no
	`tonumber()` calls in the four arithmetic functions — the
	only place strings meet `number` math is `Format`, which
	returns a display string (e.g. "1.2K") and is read by the
	HUD, never the authoritative source.

	Representation. A "BigNumber" is the bare decimal string.
	The module is the function namespace, not a constructor —
	mirrors how `string` works in Luau. Every entry point
	accepts and returns a string, or in the case of the
	predicates, a boolean.

	Canonical form. The output of every arithmetic function is
	stripped of leading zeros and decimal-trailing zeros; the
	canonical zero is the string "0" and the canonical one is
	"1". Sanitize enforces this on the way in, so callers can
	trust that a string they pass in is either valid or rejected
	(nothing partial).

	No signs. Money isn't signed math. `Subtract` clamps to "0"
	when a < b rather than returning a negative; if you need
	signed math, write a different module.

	Limits. There is no internal length cap. The longest valid
	output is the sum of the input lengths plus one carry.
	Multiply is bounded by `len(a) + len(b) + 1` output digits
	(which is the standard grade-school bound).
]]

local BigNumber = {}

-- --- Sanitize ---------------------------------------------------

-- Normalize a candidate BigNumber string. Returns the canonical
-- form on success, nil on any malformed input.
--
-- Accepts: "0", "1", "100", "1234.5678", "00001.5000", ".5",
--   "5."
-- Rejects: "", "  ", "abc", "1.2.3", "1e10", "NaN", "Infinity",
--   "-5" (no signs), nil, 42 (non-string), strings with embedded
--   whitespace, strings with non-digit/non-dot characters.
local function sanitize(input: any): string?
	if type(input) ~= 'string' then
		return nil
	end
	if #input == 0 then
		return nil
	end
	-- Single-pass scan: at most one dot, all other chars
	-- must be digits.
	local dotSeen = false
	for i = 1, #input do
		local c = string.sub(input, i, i)
		if c == '.' then
			if dotSeen then
				return nil
			end
			dotSeen = true
		elseif c < '0' or c > '9' then
			return nil
		end
	end
	-- Split integer and fractional parts so we can strip
	-- leading zeros from the integer and trailing zeros from
	-- the fraction.
	local intPart, fracPart = string.match(input, '^([^.]*)%.?(.*)$')
	if not intPart then
		return nil
	end
	-- Strip leading zeros from the integer part.
	intPart = string.gsub(intPart, '^0+', '')
	-- Strip trailing zeros from the fraction.
	if fracPart and #fracPart > 0 then
		fracPart = string.gsub(fracPart, '0+$', '')
	end
	-- If the integer part is empty, the value is fractional:
	-- re-prefix "0" so we don't return ".5" for "0.5".
	if #intPart == 0 then
		intPart = '0'
	end
	-- If both parts are zero, canonical zero.
	if intPart == '0' and (not fracPart or #fracPart == 0) then
		return '0'
	end
	-- If the fraction is empty, no decimal point.
	if not fracPart or #fracPart == 0 then
		return intPart
	end
	return intPart .. '.' .. fracPart
end
BigNumber.sanitize = sanitize

local function isValid(input: any): boolean
	return sanitize(input) ~= nil
end
BigNumber.isValid = isValid

-- Forward declaration: `compare` is referenced by
-- `subtract` (line ~282) and `divide` (line ~457), which
-- are defined before `compare` itself. A real local
-- binding (not a type-only annotation) is needed so the
-- closure those functions capture resolves to the same
-- `compare` that the body below assigns into. The body
-- below is the canonical definition; this line just gives
-- selene a name to validate against.
local compare: any = nil

-- --- Internal: split a sanitized string into integer + fraction -
-- Returns (intDigits, fracDigits, hasDecimal). Both arrays are
-- in big-endian order (most significant first), which is the
-- natural Roblox table-iteration order. Both are stripped of
-- leading/trailing zeros by sanitize, so neither is empty
-- unless the canonical zero was passed (handled by the caller).
local function _split(a: string): ({ number }, { number }, boolean)
	local hasDecimal = string.find(a, '.', 1, true) ~= nil
	local intStr: string
	local fracStr: string
	if hasDecimal then
		local m1, m2 = string.match(a, '^(%d+)%.(%d+)$')
		if not m1 then
			-- sanitize() rejects malformed decimals; we
			-- should never get here. Return a safe default.
			return { 0 }, { 0 }, false
		end
		intStr = m1
		fracStr = m2 :: string
	else
		intStr = a
		fracStr = ''
	end
	-- Strip leading zeros from the integer. The caller should
	-- have already run sanitize, so this is defensive.
	intStr = string.gsub(intStr, '^0+', '')
	if #intStr == 0 then
		intStr = '0'
	end
	local intDigits: { number } = {}
	for i = 1, #intStr do
		intDigits[#intDigits + 1] = tonumber(string.sub(intStr, i, i)) :: number
	end
	local fracDigits: { number } = {}
	for i = 1, #fracStr do
		fracDigits[#fracDigits + 1] = tonumber(string.sub(fracStr, i, i)) :: number
	end
	return intDigits, fracDigits, hasDecimal
end

-- --- Internal: join digits + strip leading zeros ---------------

local function _join(intDigits: { number }, fracDigits: { number }, hasDecimal: boolean): string
	if #intDigits == 0 then
		-- Should never happen post-sanitize, but be defensive.
		return '0'
	end
	-- Strip leading zeros from the integer part.
	local firstNonZero = 1
	while firstNonZero <= #intDigits and intDigits[firstNonZero] == 0 do
		firstNonZero += 1
	end
	if firstNonZero > #intDigits then
		-- All-zero integer part. The canonical zero is "0"
		-- with no fractional part — UNLESS the fraction
		-- carries the value (e.g. 0.5 - 0.25), in which case
		-- the result is "0.<frac>", not "0".
		if not hasDecimal or #fracDigits == 0 then
			return '0'
		end
		local lastNonZero = #fracDigits
		while lastNonZero > 0 and fracDigits[lastNonZero] == 0 do
			lastNonZero -= 1
		end
		if lastNonZero == 0 then
			return '0'
		end
		local fracStr = ''
		for i = 1, lastNonZero do
			fracStr ..= tostring(fracDigits[i])
		end
		return '0.' .. fracStr
	end
	local intStr = ''
	for i = firstNonZero, #intDigits do
		intStr ..= tostring(intDigits[i])
	end
	if not hasDecimal or #fracDigits == 0 then
		return intStr
	end
	-- Strip trailing zeros from the fraction.
	local lastNonZero = #fracDigits
	while lastNonZero > 0 and fracDigits[lastNonZero] == 0 do
		lastNonZero -= 1
	end
	if lastNonZero == 0 then
		return intStr
	end
	local fracStr = ''
	for i = 1, lastNonZero do
		fracStr ..= tostring(fracDigits[i])
	end
	return intStr .. '.' .. fracStr
end

-- --- Add -------------------------------------------------------

-- Column addition from the right, with carries. Aligns the
-- fractional parts by padding the shorter one with zeros.
local function add(a: string, b: string): string
	if not isValid(a) or not isValid(b) then
		error('BigNumber.Add: invalid input')
	end
	if a == '0' then
		return b
	end
	if b == '0' then
		return a
	end
	local aInt, aFrac, aHasDec = _split(a)
	local bInt, bFrac, bHasDec = _split(b)
	-- Pad the shorter fraction with zeros so we can add
	-- digit-by-digit. Same for the integer if needed (we
	-- add with carries from the right, so the integer sides
	-- don't need to be the same length — we just process
	-- them in reverse).
	local maxFrac = math.max(#aFrac, #bFrac)
	for i = #aFrac + 1, maxFrac do
		aFrac[i] = 0
	end
	for i = #bFrac + 1, maxFrac do
		bFrac[i] = 0
	end
	-- Add the fractional part right-to-left.
	local fracOut: { number } = {}
	local carry = 0
	for i = maxFrac, 1, -1 do
		local s = (aFrac[i] :: number) + (bFrac[i] :: number) + carry
		fracOut[i] = s % 10
		carry = math.floor(s / 10)
	end
	-- Add the integer part right-to-left, picking up the
	-- carry from the fraction.
	local maxInt = math.max(#aInt, #bInt)
	local intOut: { number } = {}
	for i = 0, maxInt do
		-- Position i counts places from the right (0 = ones).
		-- aInt is big-endian, so position i reads index
		-- #aInt - i, valid only while i < #aInt. (The old
		-- `i <= #aInt` + `#aInt - i + 1` indexing was off by
		-- one: it read past the array for i = 0 and shifted
		-- every digit one place too significant, so any two
		-- nonzero inputs returned (a + b) * 10.)
		local aDigit = (i < #aInt) and (aInt[#aInt - i] :: number) or 0
		local bDigit = (i < #bInt) and (bInt[#bInt - i] :: number) or 0
		local s = aDigit + bDigit + carry
		intOut[i + 1] = s % 10
		carry = math.floor(s / 10)
	end
	if carry > 0 then
		intOut[#intOut + 1] = carry
	end
	-- Reverse intOut to big-endian.
	local intOutBE: { number } = {}
	for i = 1, #intOut do
		intOutBE[i] = intOut[#intOut - i + 1] :: number
	end
	-- A decimal result iff EITHER input had a decimal.
	local hasDecimalOut = aHasDec or bHasDec
	-- If the fraction is all zero, drop it.
	if hasDecimalOut then
		local lastNonZero = #fracOut
		while lastNonZero > 0 and fracOut[lastNonZero] == 0 do
			lastNonZero -= 1
		end
		if lastNonZero == 0 then
			hasDecimalOut = false
		end
	end
	return _join(intOutBE, fracOut, hasDecimalOut)
end
BigNumber.Add = add

-- --- Subtract --------------------------------------------------

-- Requires a >= b; otherwise returns "0" (money, not signed).
-- The Compare predicate is the recommended way to check before
-- calling, so callers can branch on a < b themselves.
-- (Forward references to `compare` below are resolved at call
-- time: Luau local-function declarations create closures that
-- capture upvalues by name, not at the point of definition.)
local function subtract(a: string, b: string): string
	if not isValid(a) or not isValid(b) then
		error('BigNumber.Subtract: invalid input')
	end
	if b == '0' then
		return a
	end
	if compare(a, b) < 0 then
		return '0'
	end
	if compare(a, b) == 0 then
		return '0'
	end
	local aInt, aFrac, aHasDec = _split(a)
	local bInt, bFrac, bHasDec = _split(b)
	-- Pad both fractions to the same length.
	local maxFrac = math.max(#aFrac, #bFrac)
	for i = #aFrac + 1, maxFrac do
		aFrac[i] = 0
	end
	for i = #bFrac + 1, maxFrac do
		bFrac[i] = 0
	end
	-- Pad the integer parts to the same length too — easier
	-- to subtract when they're aligned. The arrays are
	-- big-endian, so padding must PREPEND zeros (the most
	-- significant side). Appending at the tail (the old
	-- behavior) shifted the shorter value left by the length
	-- difference — "100000 - 1000" padded 1000 to 100000 and
	-- returned 0.
	local maxInt = math.max(#aInt, #bInt)
	for _ = #aInt + 1, maxInt do
		table.insert(aInt, 1, 0)
	end
	for _ = #bInt + 1, maxInt do
		table.insert(bInt, 1, 0)
	end
	-- Subtract right-to-left with borrow on the integer
	-- part. Fractions are subtracted independently; the
	-- borrow on the integer part is set if a < b on the
	-- fractional part. (Standard "subtract from right with
	-- borrow" mechanics.)
	local fracOut: { number } = {}
	local borrow = 0
	for i = maxFrac, 1, -1 do
		local diff = (aFrac[i] :: number) - (bFrac[i] :: number) - borrow
		if diff < 0 then
			diff += 10
			borrow = 1
		else
			borrow = 0
		end
		fracOut[i] = diff
	end
	-- Integer subtract right-to-left.
	local intOut: { number } = {}
	for i = maxInt, 1, -1 do
		local diff = (aInt[i] :: number) - (bInt[i] :: number) - borrow
		if diff < 0 then
			diff += 10
			borrow = 1
		else
			borrow = 0
		end
		intOut[i] = diff
	end
	-- borrow should be 0 here because Compare(a, b) > 0.
	local hasDecimalOut = aHasDec or bHasDec
	if hasDecimalOut then
		local lastNonZero = #fracOut
		while lastNonZero > 0 and fracOut[lastNonZero] == 0 do
			lastNonZero -= 1
		end
		if lastNonZero == 0 then
			hasDecimalOut = false
		end
	end
	return _join(intOut, fracOut, hasDecimalOut)
end
BigNumber.Subtract = subtract

-- --- Multiply --------------------------------------------------

-- Single-pass digit-by-digit: every digit of `b` (the
-- multiplier, which is a small non-negative integer) multiplies
-- every digit of `a`, accumulated with carries.
--
-- The output is bounded by `len(a) + number_of_digits(b) + 1`
-- digits, which is the standard grade-school bound. Money
-- isn't multiplied by decimals in this codebase, so the second
-- argument is a small integer (0..1_000_000) — we accept it as
-- a number and convert internally.
local function multiply(a: string, mult: number): string
	if not isValid(a) then
		error('BigNumber.Multiply: invalid input')
	end
	if type(mult) ~= 'number' or mult ~= mult or mult < 0 or mult > 1_000_000 or math.floor(mult) ~= mult then
		error('BigNumber.Multiply: multiplier must be a non-negative integer in [0, 1000000]')
	end
	if mult == 0 or a == '0' then
		return '0'
	end
	if mult == 1 then
		return a
	end
	local aInt, aFrac, aHasDec = _split(a)
	-- Treat a as a flat digit array: integer part + fraction
	-- part. The total number of fractional digits in the
	-- output is the same as a's (mult is an integer).
	local flat: { number } = {}
	for _, d in ipairs(aInt) do
		flat[#flat + 1] = d
	end
	for _, d in ipairs(aFrac) do
		flat[#flat + 1] = d
	end
	-- Multiply each digit by `mult`, accumulating in a
	-- parallel buffer.
	local out: { number } = {}
	for i = 1, #flat do
		out[i] = (flat[i] :: number) * mult
	end
	-- Propagate carries right-to-left, including into the
	-- integer part if the carry spills past the original
	-- integer/fraction boundary. The boundary between aInt
	-- and aFrac is at index `#aInt`. Carries flowing left of
	-- index 1 extend the integer part.
	local carry = 0
	for i = #out, 1, -1 do
		local s = (out[i] :: number) + carry
		out[i] = s % 10
		carry = math.floor(s / 10)
	end
	while carry > 0 do
		-- Insert at the front.
		local s = carry
		table.insert(out, 1, s % 10)
		carry = math.floor(s / 10)
	end
	-- Split back into integer + fraction at the original
	-- boundary.
	local newInt: { number } = {}
	local newFrac: { number } = {}
	-- If the carry loop inserted new leading digits, `out`
	-- grew at the front — the integer/fraction boundary moves
	-- right with it. The fraction is always the LAST #aFrac
	-- digits of `out`. (The old `boundary = #aInt` kept the
	-- unshifted boundary, so any carry-overflowed product
	-- misfiled its least-significant digit as a fraction and
	-- dropped it: 7 x 11 returned "7", 1000 x 3600 "3600".)
	local boundary = #out - #aFrac
	for i = 1, #out do
		if i <= boundary then
			-- Inside the original integer length.
			newInt[#newInt + 1] = out[i] :: number
		else
			-- Past the boundary: either fraction (if the
			-- boundary didn't shift) or a mix of new
			-- integer-leading + fraction (if it did).
			-- The carry-shift case: if `out` grew by one
			-- due to the leading carry, then the new
			-- integer is indices 1..boundary and the
			-- fraction is indices (boundary+1)..#out —
			-- same as the unshifted case in terms of
			-- length. So this branch is always "fraction
			-- digits".
			newFrac[#newFrac + 1] = out[i] :: number
		end
	end
	-- The fraction has `#aFrac` digits by construction.
	-- Trailing-zero strip is handled by _join.
	local hasDecimalOut = aHasDec and #newFrac > 0
	return _join(newInt, newFrac, hasDecimalOut)
end
BigNumber.Multiply = multiply

-- --- MultiplyDecimal --------------------------------------------------

-- Exact multiplication by a terminating decimal string:
-- MultiplyDecimal('100', '1.5') == '150',
-- MultiplyDecimal('1000', '1.25') == '1250',
-- MultiplyDecimal('100', '1.5625') == '156.25'.
--
-- Phase 2.11: trait/mutation sell multipliers are fractional
-- ('1.5', '2.5', '1.75') and sell math must be exact — float
-- dust ('1.1000000000000001') would corrupt canonical money
-- strings. Both operands reduce to integer digit strings, so
-- the decimal point is placed by digit counting: exact by
-- construction for terminating decimals, with no division,
-- no remainder, and no rounding at any step.
--
-- `decimalStr` must be a positive terminating decimal with at
-- most 6 significant digits (keeps the integer multiplier
-- inside Multiply's [0, 1000000] bound). `a` must be a valid
-- BigNumber (fractional values chain exactly). Throws on any
-- malformed input.
local function multiplyDecimal(a: string, decimalStr: string): string
	if not isValid(a) then
		error('BigNumber.MultiplyDecimal: invalid input')
	end
	if type(decimalStr) ~= 'string' or #decimalStr == 0 then
		error('BigNumber.MultiplyDecimal: multiplier must be a decimal string')
	end
	local intPart = string.match(decimalStr, '^(%d+)%.?%d*$')
	local fracPart = string.match(decimalStr, '^%d+%.?(%d*)$')
	if not intPart or not fracPart then
		error('BigNumber.MultiplyDecimal: multiplier must match digits[.digits]')
	end
	local digits = intPart .. fracPart
	digits = string.gsub(digits, '^0+', '')
	if #digits == 0 then
		error('BigNumber.MultiplyDecimal: multiplier must be positive')
	end
	if #digits > 6 then
		error('BigNumber.MultiplyDecimal: multiplier exceeds 6 significant digits')
	end
	local num = tonumber(digits)
	if not num or num <= 0 or num > 1_000_000 or num ~= math.floor(num) then
		error('BigNumber.MultiplyDecimal: multiplier out of range')
	end
	local scaleDigits = #fracPart
	-- Strip `a` to a pure integer digit string (remembering its
	-- own fraction length): integer x integer below, so no
	-- floored division ever touches a fractional dividend.
	local aInt, aFrac, _ = _split(a)
	local flatParts: { string } = {}
	for _, d in ipairs(aInt) do
		flatParts[#flatParts + 1] = tostring(d)
	end
	for _, d in ipairs(aFrac) do
		flatParts[#flatParts + 1] = tostring(d)
	end
	local flat = table.concat(flatParts)
	flat = string.gsub(flat, '^0+', '')
	if flat == '' then
		return '0'
	end
	local totalFrac = #aFrac + scaleDigits
	local scaledInt = multiply(flat, num)
	-- Decimal point goes totalFrac digits from the right. The true
	-- value terminates within totalFrac digits (integer x integer
	-- over 10^totalFrac), so digit-string placement is exact by
	-- construction — no division, no remainder, no rounding.
	local intStr: string
	local fracStr: string
	if #scaledInt > totalFrac then
		intStr = string.sub(scaledInt, 1, #scaledInt - totalFrac)
		fracStr = string.sub(scaledInt, #scaledInt - totalFrac + 1)
	else
		intStr = '0'
		fracStr = string.rep('0', totalFrac - #scaledInt) .. scaledInt
	end
	local canonical = sanitize(intStr .. '.' .. fracStr)
	if not canonical then
		error('BigNumber.MultiplyDecimal: canonicalization failed')
	end
	return canonical
end
BigNumber.MultiplyDecimal = multiplyDecimal

-- --- Divide ----------------------------------------------------

-- Floor division. The quotient's integer part is exact; the
-- fractional part is dropped. Throws on divide-by-zero (no
-- canonical "infinity" string). The DIVISOR must be a whole
-- number — a fractional divisor is a loud error, not a silent
-- truncation (the long-division loop below works on integer
-- digit arrays only; a fractional dividend is fine, because
-- truncating it before floor division is mathematically
-- identical to floor(a / b)).
local function divide(a: string, b: string): string
	if not isValid(a) or not isValid(b) then
		error('BigNumber.Divide: invalid input')
	end
	if b == '0' then
		error('BigNumber.Divide: divide by zero')
	end
	if string.find(b, '.', 1, true) then
		error('BigNumber.Divide: fractional divisor not supported (whole-number divisors only)')
	end
	if a == '0' then
		return '0'
	end
	if compare(a, b) < 0 then
		return '0'
	end
	if compare(a, b) == 0 then
		return '1'
	end
	-- Long division on the integer parts. We work in big-
	-- endian digit arrays, scanning left to right.
	local aInt, _, _ = _split(a)
	local bInt, _, _ = _split(b)
	-- Strip leading zeros from the divisor.
	while #bInt > 1 and bInt[1] == 0 do
		table.remove(bInt, 1)
	end
	-- Compare a's leading prefix to b: build up the running
	-- remainder digit by digit.
	local rem: { number } = {}
	local out: { number } = {}
	for i = 1, #aInt do
		rem[#rem + 1] = aInt[i] :: number
		-- Strip leading zeros from the remainder before
		-- comparing.
		while #rem > 1 and rem[1] == 0 do
			table.remove(rem, 1)
		end
		-- Find the largest q in 0..9 such that
		-- q * bInt <= rem.
		local q = 0
		for cand = 9, 0, -1 do
			-- Compute cand * bInt.
			local prod: { number } = {}
			local carry = 0
			for j = #bInt, 1, -1 do
				local s = (bInt[j] :: number) * cand + carry
				prod[j] = s % 10
				carry = math.floor(s / 10)
			end
			while carry > 0 do
				table.insert(prod, 1, carry % 10)
				carry = math.floor(carry / 10)
			end
			-- Strip leading zeros.
			while #prod > 1 and prod[1] == 0 do
				table.remove(prod, 1)
			end
			-- Compare prod to rem.
			local cmp = 0
			if #prod > #rem then
				cmp = 1
			elseif #prod < #rem then
				cmp = -1
			else
				for k = 1, #prod do
					if prod[k] < rem[k] then
						cmp = -1
						break
					elseif prod[k] > rem[k] then
						cmp = 1
						break
					end
				end
			end
			if cmp <= 0 then
				q = cand
				break
			end
		end
		out[#out + 1] = q
		-- Subtract q * bInt from rem.
		local prod: { number } = {}
		local carry = 0
		for j = #bInt, 1, -1 do
			local s = (bInt[j] :: number) * q + carry
			prod[j] = s % 10
			carry = math.floor(s / 10)
		end
		while carry > 0 do
			table.insert(prod, 1, carry % 10)
			carry = math.floor(carry / 10)
		end
		-- Align prod and rem to the same length.
		while #prod < #rem do
			table.insert(prod, 1, 0)
		end
		-- Subtract.
		local borrow = 0
		local newRem: { number } = {}
		for k = #rem, 1, -1 do
			local diff = (rem[k] :: number) - (prod[k] :: number) - borrow
			if diff < 0 then
				diff += 10
				borrow = 1
			else
				borrow = 0
			end
			newRem[k] = diff
		end
		rem = newRem
	end
	-- Strip leading zeros from out.
	while #out > 1 and out[1] == 0 do
		table.remove(out, 1)
	end
	return _join(out, {}, false)
end
BigNumber.Divide = divide

-- --- Compare ---------------------------------------------------

-- Returns -1, 0, or 1. Sanitized inputs only.
-- Assigned into the forward-declared local at the top of
-- this file so `subtract` and `divide` (which are defined
-- before this body) can call it through closure capture.
compare = function(a: string, b: string): number
	if not isValid(a) or not isValid(b) then
		error('BigNumber.Compare: invalid input')
	end
	-- Fast path: equal strings.
	if a == b then
		return 0
	end
	-- Canonical zero equality. After sanitize, "0", "0.0",
	-- "0.00" all canonicalize to "0", so the a == b check
	-- catches them. The remaining case is "0" vs "0.0" with
	-- the unsanitized form — but sanitize is required
	-- upstream, so this never happens here.
	local aInt, aFrac, aHasDec = _split(a)
	local bInt, bFrac, bHasDec = _split(b)
	-- Compare integer lengths first.
	if #aInt < #bInt then
		return -1
	end
	if #aInt > #bInt then
		return 1
	end
	-- Integer lengths equal: compare digit by digit.
	for i = 1, #aInt do
		if aInt[i] < bInt[i] then
			return -1
		end
		if aInt[i] > bInt[i] then
			return 1
		end
	end
	-- Integers equal. Compare fractional parts: longer
	-- fraction means larger value (more digits after the
	-- point), equal length compares digit by digit.
	if not aHasDec and not bHasDec then
		return 0
	end
	if aHasDec and not bHasDec then
		-- a has a fraction, b doesn't; b's fraction is
		-- implicitly 0. a > b iff any of a's fraction is
		-- non-zero.
		for i = 1, #aFrac do
			if aFrac[i] > 0 then
				return 1
			end
		end
		return 0
	end
	if not aHasDec and bHasDec then
		for i = 1, #bFrac do
			if bFrac[i] > 0 then
				return -1
			end
		end
		return 0
	end
	-- Both have fractions: compare digit by digit, treating
	-- the shorter fraction as zero-padded. Fraction LENGTH
	-- alone says nothing (0.5 > 0.25 even though "5" is
	-- shorter than "25" — the old length-first compare
	-- returned the wrong order for exactly that case).
	local maxFrac = math.max(#aFrac, #bFrac)
	for i = 1, maxFrac do
		local ad = (i <= #aFrac) and (aFrac[i] :: number) or 0
		local bd = (i <= #bFrac) and (bFrac[i] :: number) or 0
		if ad < bd then
			return -1
		end
		if ad > bd then
			return 1
		end
	end
	return 0
end
BigNumber.Compare = compare

-- --- Predicates ------------------------------------------------

local function isZero(a: string): boolean
	local canonical = sanitize(a)
	if not canonical then
		return false
	end
	return canonical == '0'
end
BigNumber.IsZero = isZero

local function isPositive(a: string): boolean
	local canonical = sanitize(a)
	if not canonical then
		return false
	end
	return canonical ~= '0'
end
BigNumber.IsPositive = isPositive

-- --- Format (the one place strings meet number math) -----------

-- Compresses a BigNumber to a short HUD display string. The
-- canonical stored value is never affected by Format. Tonumber
-- is used here only to pick the right suffix tier; precision
-- loss is fine because the output is for display, not for any
-- authoritative mutation.
--
-- Tiers (12): '', K, M, B, T, Qa, Qi, Sx, Sp, Oc, No, Dc.
-- Above 1e33 ("Dc"), the value is rendered in scientific
-- notation with two decimal places.
local function format(a: string): string
	if not isValid(a) then
		error('BigNumber.Format: invalid input')
	end
	if a == '0' then
		return '0'
	end
	-- Split integer / fraction so we can do magnitude math
	-- on the integer part and any fractional part separately.
	local intPart, fracPart
	local m1, m2 = string.match(a, '^(%d+)%.(%d+)$')
	if m1 then
		intPart = m1
		fracPart = m2 :: string
	else
		intPart = a
		fracPart = ''
	end
	-- Magnitude: number of integer digits.
	local intDigits = #intPart
	-- One-digit values: just print them.
	if intDigits == 1 and (not fracPart or #fracPart == 0) then
		return a
	end
	-- Determine tier. Tier 0 is plain (no suffix); tier 1 is
	-- K (3 digits); tier 2 is M (6 digits); etc.
	-- A "tier" is the number of digits minus 1, divided by
	-- 3, integer-divided.
	local suffixes = { '', 'K', 'M', 'B', 'T', 'Qa', 'Qi', 'Sx', 'Sp', 'Oc', 'No', 'Dc' }
	local tier = math.floor((intDigits - 1) / 3)
	if tier == 0 then
		-- One or two digits. Just print with at most one
		-- fractional digit if there's a non-empty fraction.
		if #fracPart == 0 then
			return a
		end
		-- One decimal place.
		local oneDigit = string.sub(fracPart, 1, 1)
		return intPart .. '.' .. oneDigit
	end
	if tier >= #suffixes then
		-- Above decillion. Scientific notation: 1.23e33.
		-- We use the integer part and a leading fractional
		-- digit to build the mantissa.
		local mantissaInt = string.sub(intPart, 1, 1)
		local mantissaFrac = string.sub(intPart, 2, 2)
		local exponent = intDigits - 1
		if mantissaFrac == '' then
			return mantissaInt .. 'e' .. tostring(exponent)
		end
		return mantissaInt .. '.' .. mantissaFrac .. 'e' .. tostring(exponent)
	end
	-- Suffix tier: render the digits ABOVE the tier's magnitude,
	-- plus one decimal digit, then the suffix. For tier t the
	-- integer has (3t+1)..(3t+3) digits, so the part above the
	-- tier is the leading (intDigits - 3t) digits (1..3 of them)
	-- and the decimal digit is the next digit of the tail.
	--   '1000'    -> '1.0K'    '10550'   -> '10.5K'
	--   '650000'  -> '650.0K'  '1234567' -> '1.2M'
	-- (Phase 2.6.2 fix: the old code always rendered
	-- firstDigit.secondDigit, which is only correct at a tier's
	-- 4-digit minimum — '10550' mis-rendered as '1.0K', a 10x
	-- magnitude error, and '650000' as '6.5K', a 100x error.)
	local tierDigits = intDigits - tier * 3
	local leading = string.sub(intPart, 1, tierDigits)
	-- Always show one decimal place when a digit exists past the
	-- leading group (fractions themselves are dropped at tier 1+;
	-- they would be all zeros there).
	local decDigit = string.sub(intPart, tierDigits + 1, tierDigits + 1)
	if decDigit == '' then
		-- Unreachable while tier >= 1 guarantees at least one
		-- digit past the leading group's magnitude base, but
		-- stay defensive.
		return leading .. suffixes[tier + 1] :: string
	end
	return leading .. '.' .. decDigit .. suffixes[tier + 1] :: string
end
BigNumber.Format = format

return table.freeze(BigNumber)
