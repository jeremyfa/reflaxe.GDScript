package;

/**
	Reflection over Dictionaries (anonymous structures) and script Objects,
	matching Haxe semantics: missing fields read as null, deleteField
	removes Dictionary keys, fields() lists script variables only.
**/
class Reflect {
	public static function hasField(o: Dynamic, fieldName: String): Bool {
		if(o == null) return false;
		return untyped __gdscript__("({1} in {0})", o, fieldName);
	}

	public static function field(o: Dynamic, fieldName: String): Dynamic {
		final t: Int = untyped __gdscript__("typeof({0})", o);
		if(t == 27) { // TYPE_DICTIONARY
			return untyped __gdscript__("{0}.get({1})", o, fieldName);
		}
		if(t == 24) { // TYPE_OBJECT
			if(o == null) return null;
			final v: Dynamic = untyped __gdscript__("{0}.get({1})", o, fieldName);
			if(v == null && untyped __gdscript__("{0}.has_method({1})", o, fieldName)) {
				return untyped __gdscript__("Callable({0}, {1})", o, fieldName);
			}
			return v;
		}
		if(t == 28 && fieldName == "length") { // TYPE_ARRAY
			return untyped __gdscript__("{0}.size()", o);
		}
		if((t == 4 || t == 21) && fieldName == "length") { // TYPE_STRING(_NAME)
			return untyped __gdscript__("{0}.length()", o);
		}
		return null;
	}

	public static function setField(o: Dynamic, fieldName: String, value: Dynamic): Void {
		final t: Int = untyped __gdscript__("typeof({0})", o);
		if(t == 27) { // TYPE_DICTIONARY
			untyped __gdscript__("{0}[{1}] = {2}", o, fieldName, value);
		}
		else if(t == 24 && o != null) { // TYPE_OBJECT
			untyped __gdscript__("{0}.set({1}, {2})", o, fieldName, value);
		}
	}

	public static function getProperty(o: Dynamic, fieldName: String): Dynamic {
		if(hasField(o, "get_" + fieldName)) {
			final getter: Dynamic = field(o, "get_" + fieldName);
			return getter();
		}
		return field(o, fieldName);
	}

	public static function setProperty(o: Dynamic, fieldName: String, value: Dynamic): Void {
		if(hasField(o, "set_" + fieldName)) {
			final setter: Dynamic = field(o, "set_" + fieldName);
			setter(value);
			return;
		}
		setField(o, fieldName, value);
	}

	@:runtime public inline static function callMethod(o: Dynamic, func: haxe.Constraints.Function, args: Array<Dynamic>): Dynamic {
		return untyped __gdscript__("{0}.callv({1})", func, args);
	}

	public static function fields(o: Dynamic): Array<String> {
		final result: Array<String> = [];
		if(o == null) return result;
		final t: Int = untyped __gdscript__("typeof({0})", o);
		if(t == 27) { // TYPE_DICTIONARY
			final keys: Array<Dynamic> = untyped __gdscript__("{0}.keys()", o);
			for(k in keys) {
				if(untyped __gdscript__("typeof({0}) == TYPE_STRING", k)) {
					result.push(k);
				}
			}
		}
		else if(t == 24) { // TYPE_OBJECT: script variables only
			final list: Array<Dynamic> = untyped __gdscript__("{0}.get_property_list()", o);
			for(p in list) {
				final usage: Int = untyped __gdscript__("{0}[\"usage\"]", p);
				if(untyped __gdscript__("({0} & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0", usage)) {
					result.push(untyped __gdscript__("{0}[\"name\"]", p));
				}
			}
		}
		return result;
	}

	@:runtime public inline static function isFunction(f: Dynamic): Bool {
		return untyped __gdscript__("({0} as Variant) is Callable", f);
	}

	public static function compare<T>(a: T, b: T): Int {
		return if(untyped __gdscript__("{0} < {1}", a, b)) {
			-1;
		} else if(untyped __gdscript__("{0} > {1}", a, b)) {
			1;
		} else {
			0;
		}
	}

	@:runtime public inline static function compareMethods(f1: Dynamic, f2: Dynamic): Bool {
		return f1 == f2;
	}

	@:runtime public inline static function isObject(v: Dynamic): Bool {
		return untyped __gdscript__("(typeof({0}) == TYPE_OBJECT or typeof({0}) == TYPE_DICTIONARY or typeof({0}) == TYPE_STRING)", v);
	}

	@:runtime public inline static function isEnumValue(v: Dynamic): Bool {
		return untyped __gdscript__("(typeof({0}) == TYPE_DICTIONARY and {0}.has(\"_index\"))", v);
	}

	public static function deleteField(o: Dynamic, fieldName: String): Bool {
		final t: Int = untyped __gdscript__("typeof({0})", o);
		if(t == 27) { // TYPE_DICTIONARY
			return untyped __gdscript__("{0}.erase({1})", o, fieldName);
		}
		return false;
	}

	public static function copy<T>(o: Null<T>): Null<T> {
		if(o == null) return null;
		if(untyped __gdscript__("typeof({0}) == TYPE_DICTIONARY", o)) {
			return untyped __gdscript__("{0}.duplicate()", o);
		}
		throw "Only anonymous structures (Dictionaries) may be used with `Reflect.copy`.";
	}

	// GDScript has no variadic callables: bind the array-taking function to
	// a generated static dispatcher that emulates varargs.
	@:overload(function(f:Array<Dynamic>->Void):Dynamic {})
	public static function makeVarArgs(f: Array<Dynamic>->Dynamic): Dynamic {
		return untyped __gdscript__("HxVarArgs.make({0})", f);
	}
}
