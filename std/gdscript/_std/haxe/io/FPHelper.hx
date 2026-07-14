package haxe.io;

/**
	Float/int bit conversions backed by PackedByteArray encoding.
**/
class FPHelper {
	public static function i32ToFloat(i: Int): Float {
		final b: Dynamic = untyped __gdscript__("PackedByteArray([0, 0, 0, 0])");
		untyped __gdscript__("{0}.encode_s32(0, {1})", b, i);
		return untyped __gdscript__("{0}.decode_float(0)", b);
	}

	public static function floatToI32(f: Float): Int {
		final b: Dynamic = untyped __gdscript__("PackedByteArray([0, 0, 0, 0])");
		untyped __gdscript__("{0}.encode_float(0, {1})", b, f);
		return untyped __gdscript__("{0}.decode_s32(0)", b);
	}

	public static function i64ToDouble(low: Int, high: Int): Float {
		final b: Dynamic = untyped __gdscript__("PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])");
		untyped __gdscript__("{0}.encode_s64(0, {1})", b, (haxe.Int64.make(high, low) : Int));
		return untyped __gdscript__("{0}.decode_double(0)", b);
	}

	public static function doubleToI64(v: Float): haxe.Int64 {
		final b: Dynamic = untyped __gdscript__("PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])");
		untyped __gdscript__("{0}.encode_double(0, {1})", b, v);
		final bits: Int = untyped __gdscript__("{0}.decode_s64(0)", b);
		return bits;
	}
}
