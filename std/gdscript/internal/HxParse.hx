package gdscript.internal;

/**
	Faithful implementations of Haxe's Std.parseInt/parseFloat semantics,
	which differ from GDScript's to_int/to_float (those return 0 for
	invalid input instead of null/NaN).
**/
class HxParse {
	public static function parseInt(x: String): Null<Int> {
		if(x == null) return null;
		var i = 0;
		final len = x.length;
		while(i < len) {
			final c = StringTools.fastCodeAt(x, i);
			if(c != " ".code && c != "\t".code && c != "\n".code && c != "\r".code) break;
			i++;
		}
		var sign = 1;
		if(i < len) {
			final c = StringTools.fastCodeAt(x, i);
			if(c == "-".code) { sign = -1; i++; }
			else if(c == "+".code) i++;
		}
		// Hexadecimal
		if(i + 1 < len && StringTools.fastCodeAt(x, i) == "0".code) {
			final c = StringTools.fastCodeAt(x, i + 1);
			if(c == "x".code || c == "X".code) {
				i += 2;
				var value = 0;
				var digits = 0;
				while(i < len) {
					final h = StringTools.fastCodeAt(x, i);
					var d = -1;
					if(h >= "0".code && h <= "9".code) d = h - "0".code;
					else if(h >= "a".code && h <= "f".code) d = h - "a".code + 10;
					else if(h >= "A".code && h <= "F".code) d = h - "A".code + 10;
					if(d < 0) break;
					value = value * 16 + d;
					digits++;
					i++;
				}
				return digits > 0 ? sign * value : null;
			}
		}
		var value = 0;
		var digits = 0;
		while(i < len) {
			final c = StringTools.fastCodeAt(x, i);
			if(c < "0".code || c > "9".code) break;
			value = value * 10 + (c - "0".code);
			digits++;
			i++;
		}
		return digits > 0 ? sign * value : null;
	}

	public static function parseFloat(x: String): Float {
		if(x == null) return Math.NaN;
		var i = 0;
		final len = x.length;
		while(i < len) {
			final c = StringTools.fastCodeAt(x, i);
			if(c != " ".code && c != "\t".code && c != "\n".code && c != "\r".code) break;
			i++;
		}
		final start = i;
		if(i < len) {
			final c = StringTools.fastCodeAt(x, i);
			if(c == "-".code || c == "+".code) i++;
		}
		var digits = 0;
		while(i < len) {
			final c = StringTools.fastCodeAt(x, i);
			if(c < "0".code || c > "9".code) break;
			digits++;
			i++;
		}
		if(i < len && StringTools.fastCodeAt(x, i) == ".".code) {
			i++;
			while(i < len) {
				final c = StringTools.fastCodeAt(x, i);
				if(c < "0".code || c > "9".code) break;
				digits++;
				i++;
			}
		}
		if(digits == 0) return Math.NaN;
		// Exponent
		if(i < len) {
			final c = StringTools.fastCodeAt(x, i);
			if(c == "e".code || c == "E".code) {
				var j = i + 1;
				if(j < len) {
					final s = StringTools.fastCodeAt(x, j);
					if(s == "-".code || s == "+".code) j++;
				}
				var expDigits = 0;
				while(j < len) {
					final c2 = StringTools.fastCodeAt(x, j);
					if(c2 < "0".code || c2 > "9".code) break;
					expDigits++;
					j++;
				}
				if(expDigits > 0) i = j;
			}
		}
		final slice = x.substr(start, i - start);
		return untyped __gdscript__("{0}.to_float()", slice);
	}
}
