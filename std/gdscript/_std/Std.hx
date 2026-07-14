package;

extern class Std {
	@:deprecated('Std.is is deprecated. Use Std.isOfType instead.')
	@:runtime public inline static function is(v: Dynamic, t: Dynamic): Bool return isOfType(v, t);

	// Dispatches at runtime through the generated HxType registry: the type
	// argument may be a Script, a builtin sentinel (&"hx:String", ...) or an
	// interface sentinel, none of which work in a raw `is` expression.
	@:runtime public inline static function isOfType(v: Dynamic, t: Dynamic): Bool {
		return untyped __gdscript__("HxType.is_of_type({0}, {1})", v, t);
	}

	@:deprecated('Std.instance() is deprecated. Use Std.downcast() instead.')
	@:runtime public inline static function instance<T: {}, S: T>(value: T, c: Class<S>): S return downcast(value, c);

	@:runtime public inline static function downcast<T: {}, S: T>(value: T, c: Class<S>): S {
		return untyped __gdscript__("({0} if HxType.is_of_type({0}, {1}) else null)", value, c);
	}

	// Haxe-style string conversion (integral floats without trailing .0,
	// enums as Name(params)), through the generated HxDyn runtime.
	@:runtime public inline static function string(s: Dynamic): String {
		return untyped __gdscript__("HxDyn.hx_string({0})", s);
	}

	@:native("int")
	public static function int(x: Float): Int;

	// GDScript's to_int/to_float return 0 for invalid input; Haxe expects
	// null/NaN, so these go through a faithful parser.
	@:runtime public inline static function parseInt(x: String): Null<Int> {
		return gdscript.internal.HxParse.parseInt(x);
	}

	@:runtime public inline static function parseFloat(x: String): Float {
		return gdscript.internal.HxParse.parseFloat(x);
	}

	@:nativeFunctionCode("floor(randf() * {arg0})")
	public static function random(x: Int): Int;
}
