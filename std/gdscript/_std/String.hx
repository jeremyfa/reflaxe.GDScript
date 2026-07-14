package;

@:coreApi
extern class String {
	// ----------------------------
	// Haxe String Functions
	// ----------------------------

	// ----------
	// constructor
	@:nativeFunctionCode("{arg0}")
	public function new(string: String);

	// ----------
	// @:nativeName
	@:nativeName("length()")
	public var length(default, null): Int;

	@:nativeName("to_upper")
	public function toUpperCase(): String;

	@:nativeName("to_lower")
	public function toLowerCase(): String;

	@:runtime public inline function indexOf(str: String, ?startIndex: Int): Int {
		// Haxe allows a null start index (meaning 0).
		return find(str, startIndex != null ? startIndex : 0);
	}

	@:runtime public inline function substr(pos: Int, ?len: Int): String {
		return len != null ? gdSubstr(pos, len) : gdSubstr(pos, -1);
	}

	// ----------
	// @:native
	@:native("char")
	public static function fromCharCode(code: Int): String;

	// ----------
	// @:nativeFunctionCode
	@:runtime public inline function charAt(index: Int): String {
		// Haxe returns an empty string out of bounds; GDScript errors.
		return (index >= 0 && index < length) ? gdSubstr(index, 1) : "";
	}

	@:nativeFunctionCode("{this}")
	public function toString(): String;

	// ----------
	// @:runtime inline
	@:runtime public inline function charCodeAt(index: Int): Null<Int> {
		return if(index >= 0 && index < length) {
			unicodeAt(index);
		} else {
			null;
		}
	}

	@:runtime public inline function lastIndexOf(str: String, ?startIndex: Int): Int {
		return startIndex != null ? rfind(str, startIndex) : rfind(str, -1);
	}

	@:runtime public inline function split(delimiter: String): Array<String> {
		return untyped __gdscript__("Array(Array({0}.split({1})), Variant.Type.TYPE_STRING, \"\", null)", this, delimiter);
	}

	@:runtime public inline function substring(startIndex: Int, ?endIndex: Int): String {
		// Haxe semantics: negative indices clamp to 0, and if
		// startIndex > endIndex the two are swapped.
		return gdscript.internal.HxString.substring(this, startIndex, endIndex != null ? endIndex : -1);
	}

	// ----------------------------
	// GDScript String Functions
	//
	// (gotta keep these private cause @:coreApi requires all 
	//  fields that don't match the api to be explicitly private).
	// ----------------------------
	@:nativeName("unicode_at") private function unicodeAt(at: Int): Int;
	@:nativeName("rfind") private function rfind(what: String, from: Int = -1): Int;
	@:nativeName("find") private function find(what: String, from: Int = 0): Int;
	@:nativeName("findn") private function findNoCase(what: String, from: Int = 0): Int;
	@:nativeName("length") private function getLength(): Int;
	@:nativeName("substr") private function gdSubstr(pos: Int, len: Int = -1): String;
}
