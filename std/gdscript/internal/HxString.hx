package gdscript.internal;

/**
	String helpers implementing Haxe semantics that differ from GDScript's.
**/
class HxString {
	/**
		Haxe String.substring: negative indices clamp to 0, indices beyond
		the length clamp to the length, and start/end swap when reversed.
		An endIndex of -1 stands for "to the end" (null in the Haxe API).
	**/
	public static function substring(s: String, startIndex: Int, endIndex: Int): String {
		final len = s.length;
		var start = startIndex < 0 ? 0 : startIndex;
		var end = endIndex < 0 ? len : (endIndex > len ? len : endIndex);
		if(start > end) {
			final tmp = start;
			start = end;
			end = tmp;
		}
		if(start >= len) return "";
		return untyped __gdscript__("{0}.substr({1}, {2})", s, start, end - start);
	}
}
