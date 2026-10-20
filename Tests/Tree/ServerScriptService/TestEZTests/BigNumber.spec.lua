--!strict
--!native
--[[
	BigNumber.spec
	==============
	Phase 2.1: pure-function tests for the BigNumber module.
	No Roblox state; this spec just exercises sanitize +
	arithmetic on a flat fixture list + a fuzz.

	Run in TestEZ.

	Phase 2.6.1: a regression egg was added for the economy-
	integrity fix. Every BigNumber bug found during the incident
	has a named fixture that FAILS on the pre-fix code:
	  * Add x10 shift        -> Add('650000','10550') was '6605500'
	  * Subtract mis-padding -> Subtract('100000','1000') was '0'
	  * Multiply boundary    -> Multiply('1000',3600) was '3600'
	  * Compare frac length  -> Compare('0.5','0.25') was -1
	  * _join fraction loss  -> Subtract('0.5','0.25') was '0'
	  * IsZero raw compare   -> IsZero('0.0') was false
	The fuzz itself was rewritten: the Phase 2.1 fuzz recomputed
	Add(a, b) and compared it to itself (tautological — it could
	never fail on ANY implementation). The replacement checks
	against Lua double arithmetic, which is exact for integers
	below 2^53, plus an inverse-property invariant for operands
	far beyond double precision.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local BigNumber = require(ReplicatedStorage.Utility.BigNumber)

	describe('BigNumber.sanitize', function()
		it('accepts canonical integer strings', function()
			expect(BigNumber.sanitize('0')).to.equal('0')
			expect(BigNumber.sanitize('1')).to.equal('1')
			expect(BigNumber.sanitize('100')).to.equal('100')
			expect(BigNumber.sanitize('12345678901234567890')).to.equal('12345678901234567890')
		end)

		it('strips leading zeros from integers', function()
			expect(BigNumber.sanitize('00001')).to.equal('1')
			expect(BigNumber.sanitize('0000')).to.equal('0')
		end)

		it('handles decimals with trailing-zero strip', function()
			expect(BigNumber.sanitize('1.50')).to.equal('1.5')
			expect(BigNumber.sanitize('1.5000')).to.equal('1.5')
			expect(BigNumber.sanitize('0.0')).to.equal('0')
			expect(BigNumber.sanitize('0.00')).to.equal('0')
		end)

		it('rejects malformed input', function()
			expect(BigNumber.sanitize('')).to.equal(nil)
			expect(BigNumber.sanitize('  ')).to.equal(nil)
			expect(BigNumber.sanitize('abc')).to.equal(nil)
			expect(BigNumber.sanitize('1.2.3')).to.equal(nil)
			expect(BigNumber.sanitize('1e10')).to.equal(nil)
			expect(BigNumber.sanitize('NaN')).to.equal(nil)
			expect(BigNumber.sanitize('Infinity')).to.equal(nil)
			expect(BigNumber.sanitize('-5')).to.equal(nil)
			expect(BigNumber.sanitize(nil)).to.equal(nil)
			expect(BigNumber.sanitize(42)).to.equal(nil)
		end)
	end)

	describe('BigNumber.Add', function()
		it('adds simple integers', function()
			expect(BigNumber.Add('1', '2')).to.equal('3')
			expect(BigNumber.Add('100', '250')).to.equal('350')
		end)

		it('handles carry across positions', function()
			expect(BigNumber.Add('99', '1')).to.equal('100')
			expect(BigNumber.Add('999', '1')).to.equal('1000')
			expect(BigNumber.Add('99999999999999999999', '1')).to.equal('100000000000000000000')
		end)

		it('treats zero as identity', function()
			expect(BigNumber.Add('0', '42')).to.equal('42')
			expect(BigNumber.Add('42', '0')).to.equal('42')
			expect(BigNumber.Add('0', '0')).to.equal('0')
		end)

		it('adds decimals', function()
			expect(BigNumber.Add('0.5', '0.5')).to.equal('1')
			expect(BigNumber.Add('1.25', '2.5')).to.equal('3.75')
			expect(BigNumber.Add('0.1', '0.2')).to.equal('0.3')
		end)
	end)

	describe('BigNumber.Subtract', function()
		it('subtracts simple integers', function()
			expect(BigNumber.Subtract('5', '2')).to.equal('3')
			expect(BigNumber.Subtract('100', '50')).to.equal('50')
		end)

		it('handles borrow across positions', function()
			expect(BigNumber.Subtract('100', '1')).to.equal('99')
			expect(BigNumber.Subtract('1000', '1')).to.equal('999')
			expect(BigNumber.Subtract('100000000000000000000', '1')).to.equal('99999999999999999999')
		end)

		it('clamps at zero when a < b', function()
			expect(BigNumber.Subtract('5', '10')).to.equal('0')
			expect(BigNumber.Subtract('1', '1')).to.equal('0')
		end)

		it('treats zero as identity', function()
			expect(BigNumber.Subtract('42', '0')).to.equal('42')
		end)

		it('subtracts decimals', function()
			expect(BigNumber.Subtract('1.5', '0.5')).to.equal('1')
			expect(BigNumber.Subtract('3.75', '2.5')).to.equal('1.25')
		end)
	end)

	describe('BigNumber.Multiply', function()
		it('multiplies by a small integer', function()
			expect(BigNumber.Multiply('2', 3)).to.equal('6')
			expect(BigNumber.Multiply('100', 5)).to.equal('500')
		end)

		it('handles multi-digit multiplier via repeated carry', function()
			expect(BigNumber.Multiply('7', 11)).to.equal('77')
			expect(BigNumber.Multiply('123456789', 9)).to.equal('1111111101')
		end)

		it('preserves fraction length (mult is integer)', function()
			expect(BigNumber.Multiply('1.5', 2)).to.equal('3')
			expect(BigNumber.Multiply('0.5', 4)).to.equal('2')
		end)

		it('returns zero for any zero input', function()
			expect(BigNumber.Multiply('0', 5)).to.equal('0')
			expect(BigNumber.Multiply('5', 0)).to.equal('0')
		end)

		it('rejects out-of-range multipliers', function()
			expect(function()
				BigNumber.Multiply('1', -1)
			end).to.throw()
			expect(function()
				BigNumber.Multiply('1', 1.5)
			end).to.throw()
			expect(function()
				BigNumber.Multiply('1', 1_000_001)
			end).to.throw()
		end)
	end)

	describe('BigNumber.Divide', function()
		it('divides simple integers', function()
			expect(BigNumber.Divide('10', '2')).to.equal('5')
			expect(BigNumber.Divide('100', '4')).to.equal('25')
		end)

		it('floor-divides unevenly', function()
			expect(BigNumber.Divide('7', '2')).to.equal('3')
		end)

		it('returns zero when a < b', function()
			expect(BigNumber.Divide('1', '5')).to.equal('0')
		end)

		it('returns 1 when a == b', function()
			expect(BigNumber.Divide('7', '7')).to.equal('1')
		end)

		it('throws on divide by zero', function()
			expect(function()
				BigNumber.Divide('5', '0')
			end).to.throw()
		end)
	end)

	describe('BigNumber.Compare', function()
		it('orders integers correctly', function()
			expect(BigNumber.Compare('1', '2')).to.equal(-1)
			expect(BigNumber.Compare('2', '1')).to.equal(1)
			expect(BigNumber.Compare('5', '5')).to.equal(0)
		end)

		it('orders by length first', function()
			expect(BigNumber.Compare('99', '100')).to.equal(-1)
			expect(BigNumber.Compare('100', '99')).to.equal(1)
		end)

		it('orders decimals', function()
			expect(BigNumber.Compare('0.5', '0.6')).to.equal(-1)
			expect(BigNumber.Compare('1.5', '1')).to.equal(1)
			expect(BigNumber.Compare('1.5', '1.5')).to.equal(0)
		end)
	end)

	describe('BigNumber.IsZero / IsPositive', function()
		it('recognizes zero', function()
			expect(BigNumber.IsZero('0')).to.equal(true)
			expect(BigNumber.IsZero('0.0')).to.equal(true)
			expect(BigNumber.IsZero('1')).to.equal(false)
		end)

		it('recognizes positive', function()
			expect(BigNumber.IsPositive('0')).to.equal(false)
			expect(BigNumber.IsPositive('0.0')).to.equal(false)
			expect(BigNumber.IsPositive('1')).to.equal(true)
			expect(BigNumber.IsPositive('100')).to.equal(true)
		end)
	end)

	describe('BigNumber.Format', function()
		it('renders small numbers plainly', function()
			expect(BigNumber.Format('0')).to.equal('0')
			expect(BigNumber.Format('1')).to.equal('1')
			expect(BigNumber.Format('42')).to.equal('42')
			expect(BigNumber.Format('999')).to.equal('999')
		end)

		it('uses K / M / B / T suffixes', function()
			expect(BigNumber.Format('1000')).to.equal('1.0K')
			expect(BigNumber.Format('1500')).to.equal('1.5K')
			expect(BigNumber.Format('1000000')).to.equal('1.0M')
			expect(BigNumber.Format('1500000')).to.equal('1.5M')
			expect(BigNumber.Format('1000000000')).to.equal('1.0B')
			expect(BigNumber.Format('1000000000000')).to.equal('1.0T')
		end)

		it('uses long-tier suffixes', function()
			expect(BigNumber.Format('1000000000000000')).to.equal('1.0Qa')
			expect(BigNumber.Format('1000000000000000000')).to.equal('1.0Qi')
		end)

		it('Phase 2.6.2: collector MoneyLabel fixture list', function()
			-- The Phase 2.6.2 spec's formatting list, using the
			-- project's established one-decimal style.
			expect(BigNumber.Format('0')).to.equal('0')
			expect(BigNumber.Format('5')).to.equal('5')
			expect(BigNumber.Format('999')).to.equal('999')
			expect(BigNumber.Format('1000')).to.equal('1.0K')
			expect(BigNumber.Format('10550')).to.equal('10.5K')
			expect(BigNumber.Format('1000000')).to.equal('1.0M')
			expect(BigNumber.Format('1000000000')).to.equal('1.0B')
			expect(BigNumber.Format('1000000000000')).to.equal('1.0T')
			expect(BigNumber.Format('1000000000000000')).to.equal('1.0Qa')
		end)

		it('Phase 2.6.2: mid-tier bands render the full leading group', function()
			-- Pre-2.6.2 the formatter always rendered
			-- firstDigit.secondDigit, which is only correct at a
			-- tier's 4-digit minimum: '10550' rendered '1.0K'
			-- (10x magnitude error), '650000' rendered '6.5K'
			-- (100x error), '999999' rendered '9.9K'.
			expect(BigNumber.Format('10550')).to.equal('10.5K')
			expect(BigNumber.Format('650000')).to.equal('650.0K')
			expect(BigNumber.Format('999999')).to.equal('999.9K')
			expect(BigNumber.Format('999999999999999')).to.equal('999.9T')
			expect(BigNumber.Format('1234567890123456')).to.equal('1.2Qa')
		end)

		it('Phase 2.6.2: formatting never converts through Lua numbers', function()
			-- 37-digit values are far beyond double precision; the
			-- output must still be exact, built purely from string
			-- positions (tier 12 is above the last suffix, so the
			-- scientific branch renders from the raw digits).
			expect(BigNumber.Format('1' .. string.rep('0', 36))).to.equal('1.0e36')
			expect(BigNumber.Format('9' .. string.rep('0', 36))).to.equal('9.0e36')
			expect(BigNumber.Format('9876543210987654321098765432109876543210')).to.equal('9.8e39')
		end)
	end)

	-- =================================================================
	-- Phase 2.6.1 regression egg. Each fixture below documents the
	-- value the PRE-FIX code returned; if any of those bugs is ever
	-- reintroduced, the corresponding assertion fails with the exact
	-- historical wrong value visible in the diff.
	-- =================================================================
	describe('Phase 2.6.1 regression — Add x10 shift', function()
		-- The incident: the Add digit loop read index #aInt - i + 1
		-- for position i, which is past the array for i = 0, so every
		-- real digit landed one place too significant: any two
		-- NONZERO operands returned (a + b) * 10. The a == '0' /
		-- b == '0' fast paths (return b / return a) masked the bug
		-- for pool accumulation from an empty pool, which is why
		-- Money exploded while pools looked sane.
		it('returns 660550 for the exact Studio incident', function()
			expect(BigNumber.Add('650000', '10550')).to.equal('660550')
			expect(BigNumber.Add('650000', '10550')).never.to.equal('6605500')
		end)

		it('does not shift single-digit adds', function()
			-- Pre-fix: Add('1','2') == '30'.
			expect(BigNumber.Add('1', '2')).to.equal('3')
			expect(BigNumber.Add('5', '5')).to.equal('10')
		end)

		it('does not shift carry chains', function()
			-- Pre-fix: Add('99','1') == '1000'.
			expect(BigNumber.Add('99', '1')).to.equal('100')
			expect(BigNumber.Add('999999', '1')).to.equal('1000000')
		end)

		it('repeats the incident collection sequence exactly', function()
			-- Studio observed: 650000 -> +10550 -> 6605500 ->
			-- +5 -> 66055050 -> +5 -> 660550550. The fixed
			-- sequence must be 660550 -> 660555 -> 660560.
			local money = '650000'
			money = BigNumber.Add(money, '10550')
			expect(money).to.equal('660550')
			money = BigNumber.Add(money, '5')
			expect(money).to.equal('660555')
			money = BigNumber.Add(money, '5')
			expect(money).to.equal('660560')
			money = BigNumber.Add(money, '5')
			expect(money).to.equal('660565')
		end)

		it('spec section 24 fixture list', function()
			-- (a, b, expected) — expected values are hand-derived,
			-- not computed by the module under test.
			local cases = {
				{ '0', '0', '0' },
				{ '0', '5', '5' },
				{ '5', '5', '10' },
				{ '100', '5', '105' },
				{ '1000', '50', '1050' },
				{ '650000', '10550', '660550' },
				{ '660550', '5', '660555' },
				{ '999999', '1', '1000000' },
				{ '1000000', '500000', '1500000' },
			}
			for _, case in ipairs(cases) do
				expect(BigNumber.Add(case[1], case[2])).to.equal(case[3])
			end
		end)

		it('handles mixed-length operands without fast paths', function()
			-- Neither operand is '0', so both go through the
			-- digit loop that held the x10 bug.
			expect(BigNumber.Add('12345', '678')).to.equal('13023')
			expect(BigNumber.Add('7', '123456789')).to.equal('123456796')
			expect(BigNumber.Add('50', '50')).to.equal('100')
		end)
	end)

	describe('Phase 2.6.1 regression — Subtract mis-padding', function()
		-- Pre-fix: the length-mismatch pad APPENDED zeros to the
		-- tail (least-significant side) instead of prepending, so
		-- the shorter operand was shifted left by the length
		-- difference. Historical wrong values in the comments.
		it('subtracts operands of different lengths', function()
			-- Pre-fix: Subtract('650000','10550') == '544500'.
			expect(BigNumber.Subtract('650000', '10550')).to.equal('639450')
		end)

		it('subtracts a much shorter operand', function()
			-- Pre-fix: Subtract('100000','1000') == '0' (the
			-- purchase-destroying case: TrySpendMoney silently
			-- mis-charged whenever digit counts differed).
			expect(BigNumber.Subtract('100000', '1000')).to.equal('99000')
			expect(BigNumber.Subtract('100', '50')).to.equal('50') -- pre-fix '600'
			expect(BigNumber.Subtract('100', '1')).to.equal('99')
			expect(BigNumber.Subtract('100000000000000000000', '1')).to.equal('99999999999999999999')
		end)

		it('keeps the clamp and identity contracts', function()
			expect(BigNumber.Subtract('5', '10')).to.equal('0')
			expect(BigNumber.Subtract('1', '1')).to.equal('0')
			expect(BigNumber.Subtract('42', '0')).to.equal('42')
			expect(BigNumber.Subtract('0', '0')).to.equal('0')
		end)

		it('subtracts decimals whose integer parts differ in length', function()
			expect(BigNumber.Subtract('3.75', '2.5')).to.equal('1.25')
			expect(BigNumber.Subtract('2.5', '1.25')).to.equal('1.25')
		end)
	end)

	describe('Phase 2.6.1 regression — Multiply boundary', function()
		-- Pre-fix: Multiply kept boundary = #aInt after the
		-- carry-overflow insert grew the output array, so the
		-- least-significant digit was misfiled as a fraction digit
		-- and dropped. Historical wrong values in the comments.
		it('keeps the carry-overflow digit', function()
			-- Pre-fix: Multiply('7', 11) == '7'.
			expect(BigNumber.Multiply('7', 11)).to.equal('77')
			-- Pre-fix: Multiply('99999', 2) == '19999'.
			expect(BigNumber.Multiply('99999', 2)).to.equal('199998')
		end)

		it('multiplies into a longer result', function()
			-- Pre-fix: Multiply('1000', 3600) == '3600' (the
			-- offline-earnings-scale case).
			expect(BigNumber.Multiply('1000', 3600)).to.equal('3600000')
			expect(BigNumber.Multiply('123456789', 9)).to.equal('1111111101')
		end)

		it('spec section 25 fixture list', function()
			expect(BigNumber.Multiply('5', 1)).to.equal('5')
			expect(BigNumber.Multiply('5', 0)).to.equal('0')
			expect(BigNumber.Multiply('100', 10)).to.equal('1000')
			expect(BigNumber.Multiply('1000', 3600)).to.equal('3600000')
		end)
	end)

	describe('Phase 2.6.1 regression — Compare fraction order', function()
		-- Pre-fix: the both-fractions branch compared fraction
		-- LENGTH first, so 0.5 (len 1) ordered below 0.25 (len 2).
		it('compares fractions digit-wise, not by length', function()
			expect(BigNumber.Compare('0.5', '0.25')).to.equal(1) -- pre-fix -1
			expect(BigNumber.Compare('0.25', '0.5')).to.equal(-1)
			expect(BigNumber.Compare('0.5', '0.5')).to.equal(0)
			expect(BigNumber.Compare('0.50', '0.5')).to.equal(0)
		end)

		it('compares equal-length integer parts by fraction digits', function()
			expect(BigNumber.Compare('1.05', '1.5')).to.equal(-1)
			expect(BigNumber.Compare('1.5', '1.05')).to.equal(1)
		end)
	end)

	describe('Phase 2.6.1 regression — _join fraction loss', function()
		-- Pre-fix: _join returned '0' unconditionally for an
		-- all-zero integer part, discarding a nonzero fraction.
		it('preserves a nonzero fraction over a zero integer part', function()
			-- Pre-fix: Subtract('0.5','0.25') == '0'.
			expect(BigNumber.Subtract('0.5', '0.25')).to.equal('0.25')
			expect(BigNumber.Subtract('0.75', '0.25')).to.equal('0.5')
		end)
	end)

	describe('Phase 2.6.1 regression — zero predicates canonicalize', function()
		-- Pre-fix: IsZero / IsPositive raw-string-compared instead
		-- of canonicalizing, so '0.0' read as nonzero-positive.
		it('canonicalizes before comparing', function()
			expect(BigNumber.IsZero('0.0')).to.equal(true)
			expect(BigNumber.IsZero('0.000')).to.equal(true)
			expect(BigNumber.IsPositive('0.0')).to.equal(false)
			expect(BigNumber.IsPositive('0.000')).to.equal(false)
		end)
	end)

	describe('Phase 2.6.1 regression — Divide whole-divisor contract', function()
		it('divides exactly and with floor', function()
			expect(BigNumber.Divide('10', '2')).to.equal('5')
			expect(BigNumber.Divide('660550', '10')).to.equal('66055')
			expect(BigNumber.Divide('1000000', '7')).to.equal('142857')
		end)

		it('throws on zero and on fractional divisors', function()
			expect(function()
				BigNumber.Divide('5', '0')
			end).to.throw()
			expect(function()
				BigNumber.Divide('10', '2.5')
			end).to.throw()
		end)
	end)

	describe('BigNumber.fuzz', function()
		-- Phase 2.1 fuzz was TAUTOLOGICAL: it computed Add(a, b)
		-- and compared the result to Add(a, b) — an identity that
		-- passes on any implementation, including the x10-shifted
		-- one that shipped. Phase 2.6.1 replaces it with two real
		-- oracles:
		--   1. Lua double arithmetic, exact for integers < 2^53
		--      (operands capped at 12 digits so every sum/product
		--      stays exact).
		--   2. Structural invariants that hold for operands of any
		--      size: (a + b) - b == a, Compare(a + b, a) >= 0, and
		--      digitSum(a + b) ≡ digitSum(a) + digitSum(b) (mod 9).
		-- Deterministic LCG; same seed every run so failures are
		-- reproducible.
		local state = 42
		local function nextRand()
			state = (state * 48271) % 2147483647
			return state / 2147483647
		end
		local function randomDigits(minLen, maxLen)
			local len = math.floor(nextRand() * (maxLen - minLen + 1)) + minLen
			local s = ''
			for _ = 1, len do
				s = s .. tostring(math.floor(nextRand() * 10))
			end
			-- No leading zero, so integer length is unambiguous.
			if string.sub(s, 1, 1) == '0' then
				s = '1' .. string.sub(s, 2)
			end
			return s
		end
		local function digitSum(s)
			local sum = 0
			for i = 1, #s do
				local c = string.sub(s, i, i)
				if c ~= '.' then
					sum += tonumber(c) :: number
				end
			end
			return sum
		end

		it('Add matches double arithmetic on 12-digit operands', function()
			for _ = 1, 500 do
				local a = randomDigits(1, 12)
				local b = randomDigits(1, 12)
				local expected = tostring(math.floor((tonumber(a) :: number) + (tonumber(b) :: number)))
				expect(BigNumber.Add(a, b)).to.equal(expected)
			end
		end)

		it('Subtract matches double arithmetic on 12-digit operands', function()
			for _ = 1, 500 do
				local a = randomDigits(1, 12)
				local b = randomDigits(1, 12)
				local ta, tb = tonumber(a) :: number, tonumber(b) :: number
				if tb > ta then
					a, b, ta, tb = b, a, tb, ta
				end
				-- a >= b now; exact double subtraction.
				expect(BigNumber.Subtract(a, b)).to.equal(tostring(math.floor(ta - tb)))
			end
		end)

		it('Multiply matches double arithmetic on small operands', function()
			for _ = 1, 300 do
				local a = randomDigits(1, 10)
				local m = math.floor(nextRand() * 3600)
				local expected = tostring(math.floor((tonumber(a) :: number) * m))
				expect(BigNumber.Multiply(a, m)).to.equal(expected)
			end
		end)

		it('Divide matches double arithmetic on constructed exact quotients', function()
			for _ = 1, 300 do
				local b = randomDigits(1, 6)
				local q = math.floor(nextRand() * 100000) + 1
				local a = tostring((tonumber(b) :: number) * q)
				expect(BigNumber.Divide(a, b)).to.equal(tostring(q))
			end
		end)

		it('Compare matches double arithmetic on 12-digit operands', function()
			for _ = 1, 500 do
				local a = randomDigits(1, 12)
				local b = randomDigits(1, 12)
				local ta, tb = tonumber(a) :: number, tonumber(b) :: number
				local expected = (ta > tb and 1) or (ta < tb and -1 or 0)
				expect(BigNumber.Compare(a, b)).to.equal(expected)
			end
		end)

		it('inverse property holds for 40-digit operands beyond double precision', function()
			for _ = 1, 300 do
				local a = randomDigits(30, 40)
				local b = randomDigits(1, 25)
				local sum = BigNumber.Add(a, b)
				-- (a + b) - b == a. Under the pre-fix code this
				-- failed: Add shifted digits x10 and Subtract
				-- mis-padded, so the round-trip broke immediately.
				expect(BigNumber.Subtract(sum, b)).to.equal(a)
				-- Sum is never below its own addend.
				expect(BigNumber.Compare(sum, a) >= 0).to.equal(true)
				-- Digit-sum mod 9: preserved by real addition,
				-- violated by wrong-digit output (though not by a
				-- pure x10 shift — that is what the fixtures
				-- above are for).
				local modA = digitSum(a) % 9
				local modB = digitSum(b) % 9
				local modSum = digitSum(sum) % 9
				expect(modSum).to.equal((modA + modB) % 9)
			end
		end)
	end)
end
