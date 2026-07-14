package;

/**
	The diffent possible runtime types of a value.
**/
enum ValueType {
	TNull;
	TInt;
	TFloat;
	TBool;
	TObject;
	TFunction;
	TClass(c: Class<Dynamic>);
	TEnum(e: Enum<Dynamic>);
	TUnknown;
}

/**
	Runtime type information for the GDScript target.

	Classes are represented by their generated `Script` globals, so a
	`Class<T>` value is a GDScript `Script` object. Name lookups go through
	the compiler-generated `HxType` registry. Haxe enums compile to plain
	Dictionaries, so enum-type reflection is limited.
**/
class Type {
	public static function getClass<T>(o: T): Null<Class<T>> {
		if(o == null) return null;
		return untyped __gdscript__("({0}.get_script() if typeof({0}) == TYPE_OBJECT else null)", o);
	}

	public static function getSuperClass(c: Class<Dynamic>): Null<Class<Dynamic>> {
		if(c == null) return null;
		return untyped __gdscript__("{0}.get_base_script()", c);
	}

	public static function getClassName(c: Class<Dynamic>): String {
		final name: Null<String> = untyped __gdscript__("HxType.name_of({0})", c);
		return name != null ? name : "";
	}

	public static function resolveClass(name: String): Null<Class<Dynamic>> {
		return untyped __gdscript__("HxType.resolve({0})", name);
	}

	public static function createInstance<T>(cl: Class<T>, args: Array<Dynamic>): T {
		return untyped __gdscript__("{0}.new.callv({1})", cl, args);
	}

	/**
		GDScript always runs `_init` on `new()`, so this only works for
		classes whose constructor takes no required arguments.
	**/
	public static function createEmptyInstance<T>(cl: Class<T>): T {
		return untyped __gdscript__("{0}.new()", cl);
	}

	/**
		Haxe enums compile to Dictionaries; Godot Dictionary equality is a
		recursive value comparison, which matches `enumEq` semantics for
		enums whose parameters are values (numbers, strings, enums, arrays).
	**/
	public static function enumEq<T>(a: T, b: T): Bool {
		return untyped __gdscript__("({0} == {1})", a, b);
	}

	public static function enumIndex(e: EnumValue): Int {
		return untyped __gdscript__("{0}[\"_index\"]", e);
	}

	public static function typeof(v: Dynamic): ValueType {
		final t: Int = untyped __gdscript__("typeof({0})", v);
		return switch(t) {
			case 0: TNull; // TYPE_NIL
			case 1: TBool; // TYPE_BOOL
			case 2: TInt; // TYPE_INT
			case 3: TFloat; // TYPE_FLOAT
			// Builtin classes are represented by StringName sentinels,
			// matching how the compiler emits String/Array in value position.
			case 4: TClass(untyped __gdscript__("&\"hx:String\"")); // TYPE_STRING
			case 27: TObject; // TYPE_DICTIONARY (enums indistinguishable)
			case 28: TClass(untyped __gdscript__("&\"hx:Array\"")); // TYPE_ARRAY
			case 25: TFunction; // TYPE_CALLABLE
			case 24: { // TYPE_OBJECT
				final c = getClass(v);
				c != null ? TClass(c) : TUnknown;
			}
			case _: TUnknown;
		}
	}

	public static function getInstanceFields(c: Class<Dynamic>): Array<String> {
		final out: Array<String> = [];
		if(c == null) return out;
		final props: Array<Dynamic> = untyped __gdscript__("{0}.get_script_property_list()", c);
		for(p in props) {
			final name: String = untyped __gdscript__("{0}[\"name\"]", p);
			out.push(name);
		}
		return out;
	}

	public static function getClassFields(c: Class<Dynamic>): Array<String> {
		return [];
	}

	// Enum reflection below is limited: Haxe enums are plain Dictionaries
	// on this target and enum types have no runtime representation.

	public static function getEnum(o: EnumValue): Null<Enum<Dynamic>> {
		return untyped __gdscript__(
			"(StringName(\"hxenum:\" + {0}[\"_hx_enum\"]) if typeof({0}) == TYPE_DICTIONARY and {0}.has(\"_hx_enum\") else null)", o);
	}

	public static function getEnumName(e: Enum<Dynamic>): String {
		final s: String = untyped __gdscript__("String({0})", e);
		return StringTools.startsWith(s, "hxenum:") ? s.substr(7) : s;
	}

	public static function resolveEnum(name: String): Null<Enum<Dynamic>> {
		return null;
	}

	public static function createEnum<T>(e: Enum<T>, constr: String, ?params: Array<Dynamic>): T {
		throw "Type.createEnum is not supported on the GDScript target";
	}

	public static function createEnumIndex<T>(e: Enum<T>, index: Int, ?params: Array<Dynamic>): T {
		throw "Type.createEnumIndex is not supported on the GDScript target";
	}

	public static function allEnums<T>(e: Enum<T>): Array<T> {
		return [];
	}

	public static function getEnumConstructs(e: Enum<Dynamic>): Array<String> {
		return [];
	}

	public static function enumConstructor(e: EnumValue): String {
		return "";
	}

	/**
		Haxe enums compile to Dictionaries whose entries preserve declaration
		order, so parameter values are the entries whose keys do not start
		with an underscore (_index, _hx_enum are metadata).
	**/
	public static function enumParameters(e: EnumValue): Array<Dynamic> {
		final out: Array<Dynamic> = [];
		final keys: Array<String> = untyped __gdscript__("{0}.keys()", e);
		for(k in keys) {
			if(!StringTools.startsWith(k, "_")) {
				out.push(untyped __gdscript__("{0}[{1}]", e, k));
			}
		}
		return out;
	}
}
