--!strict
--!native
--[[
	RichTextFormatter.spec
	======================
	Tests for the centralized safe-RichText builder
	(ReplicatedStorage/Utility/RichTextFormatter.lua).

	Locks in: deterministic hex conversion from the canonical
	RarityConfig colors, escape-before-wrap order (no markup
	injection from dynamic names), and plain-text fallback for
	unknown rarities.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local RichTextFormatter = require(ReplicatedStorage.Utility.RichTextFormatter)

	describe('RichTextFormatter', function()
		it('converts canonical rarity colors deterministically', function()
			expect(RichTextFormatter.RarityHex('Common')).to.equal('#B4B4B4')
			expect(RichTextFormatter.RarityHex('Legendary')).to.equal('#F5C846')
			expect(RichTextFormatter.RarityHex('Secret')).to.equal('#FFFFFF')
			expect(RichTextFormatter.RarityHex('Mythic')).to.equal('#E65A5A')
		end)

		it('falls back to white for unknown rarities', function()
			expect(RichTextFormatter.RarityHex('NotARarity')).to.equal('#FFFFFF')
			expect(RichTextFormatter.RarityHex(nil)).to.equal('#FFFFFF')
		end)

		it('escapes markup-sensitive characters (& first)', function()
			expect(RichTextFormatter.Escape('<b>A&B</b>')).to.equal('&lt;b&gt;A&amp;B&lt;/b&gt;')
			expect(RichTextFormatter.Escape('plain')).to.equal('plain')
		end)

		it('wraps escaped names in rarity color', function()
			expect(RichTextFormatter.Entity('Dog', 'Legendary', 'Animal')).to.equal('<font color="#F5C846">Dog</font>')
		end)

		it('never lets names inject markup', function()
			expect(RichTextFormatter.Entity('</font><b>', 'Common', 'Animal')).to.equal(
				'<font color="#B4B4B4">&lt;/font&gt;&lt;b&gt;</font>'
			)
		end)

		it('falls back cleanly on unusable names', function()
			expect(RichTextFormatter.Entity('', 'Common', 'Egg')).to.equal('<font color="#B4B4B4">Egg</font>')
			expect(RichTextFormatter.Entity(nil, nil, 'Egg')).to.equal('Egg')
		end)

		it('styles danger copy in fixed red with escaping', function()
			expect(RichTextFormatter.Danger('stole your')).to.equal('<font color="#FF5A5A">stole your</font>')
			expect(RichTextFormatter.Danger('<b>x</b>')).to.equal('<font color="#FF5A5A">&lt;b&gt;x&lt;/b&gt;</font>')
		end)

		it('exposes a fixed admin highlight distinct from rarity colors', function()
			expect(RichTextFormatter.AdminHex).to.equal('#A0C8FF')
			expect(RichTextFormatter.Colored(RichTextFormatter.Escape('Bob'), RichTextFormatter.AdminHex)).to.equal(
				'<font color="#A0C8FF">Bob</font>'
			)
		end)
	end)
end
