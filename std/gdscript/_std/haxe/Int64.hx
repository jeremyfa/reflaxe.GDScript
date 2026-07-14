package haxe;

/**
	GDScript integers are 64-bit, so Int64 is a plain native int. This
	replaces the cross-platform emulation class, whose arithmetic depends
	on 32-bit overflow semantics that GDScript does not have.
**/
@:transitive
abstract Int64(Int) from Int to Int {
	inline function new(x: Int)
		this = x;

	public static inline function make(high: Int32, low: Int32): Int64 {
		// Hex literals above 32 bits are not valid Haxe; emit them raw.
		return cast (untyped __gdscript__("(({0} << 32) | ({1} & 0xFFFFFFFF))", (high : Int), (low : Int)) : Int);
	}

	public static inline function ofInt(x: Int): Int64 {
		return cast x;
	}

	public static inline function toInt(x: Int64): Int {
		return cast x;
	}

	@:deprecated("Use high instead")
	public static inline function getHigh(x: Int64): Int32 {
		return x.high;
	}

	@:deprecated("Use low instead")
	public static inline function getLow(x: Int64): Int32 {
		return x.low;
	}

	public static inline function isNeg(x: Int64): Bool {
		return (x : Int) < 0;
	}

	public static inline function isZero(x: Int64): Bool {
		return (x : Int) == 0;
	}

	public static inline function compare(a: Int64, b: Int64): Int {
		final ai: Int = cast a;
		final bi: Int = cast b;
		return ai < bi ? -1 : (ai > bi ? 1 : 0);
	}

	public static function ucompare(a: Int64, b: Int64): Int {
		final ai: Int = cast a;
		final bi: Int = cast b;
		if((ai < 0) != (bi < 0)) {
			// The negative one is larger unsigned
			return ai < 0 ? 1 : -1;
		}
		return ai < bi ? -1 : (ai > bi ? 1 : 0);
	}

	public static inline function toStr(x: Int64): String {
		return Std.string((x : Int));
	}

	public static inline function divMod(dividend: Int64, divisor: Int64): { quotient: Int64, modulus: Int64 } {
		return { quotient: dividend / divisor, modulus: dividend % divisor };
	}

	public static inline function neg(x: Int64): Int64 {
		return cast -(x : Int);
	}

	public static inline function add(a: Int64, b: Int64): Int64 {
		return cast ((a : Int) + (b : Int));
	}

	public static inline function sub(a: Int64, b: Int64): Int64 {
		return cast ((a : Int) - (b : Int));
	}

	public static inline function mul(a: Int64, b: Int64): Int64 {
		return cast ((a : Int) * (b : Int));
	}

	public static inline function div(a: Int64, b: Int64): Int64 {
		return cast Std.int((a : Int) / (b : Int));
	}

	public static inline function mod(a: Int64, b: Int64): Int64 {
		return cast ((a : Int) % (b : Int));
	}

	public static inline function and(a: Int64, b: Int64): Int64 {
		return cast ((a : Int) & (b : Int));
	}

	public static inline function or(a: Int64, b: Int64): Int64 {
		return cast ((a : Int) | (b : Int));
	}

	public static inline function xor(a: Int64, b: Int64): Int64 {
		return cast ((a : Int) ^ (b : Int));
	}

	public static inline function shl(a: Int64, b: Int): Int64 {
		return cast ((a : Int) << b);
	}

	public static inline function shr(a: Int64, b: Int): Int64 {
		return cast ((a : Int) >> b);
	}

	public static function ushr(a: Int64, b: Int): Int64 {
		final ai: Int = cast a;
		if(b == 0) return cast ai;
		// Arithmetic shift then clear the sign-extended top bits.
		return cast (untyped __gdscript__("(({0} >> {1}) & (0x7FFFFFFFFFFFFFFF >> ({1} - 1)))", ai, b) : Int);
	}

	public var high(get, never): Int32;
	inline function get_high(): Int32 {
		return cast (this >> 32);
	}

	public var low(get, never): Int32;
	function get_low(): Int32 {
		return cast (untyped __gdscript__("((({0} & 0xFFFFFFFF) - 0x100000000) if ({0} & 0x80000000) != 0 else ({0} & 0xFFFFFFFF))", this) : Int);
	}

	public inline function copy(): Int64 {
		return cast this;
	}

	public inline function toString(): String {
		return Std.string(this);
	}

	@:op(-A) inline function opNeg(): Int64 return cast -this;
	@:op(~A) inline function opComplement(): Int64 return cast ~this;
	@:op(A + B) inline static function opAdd(a: Int64, b: Int64): Int64 return add(a, b);
	@:op(A - B) inline static function opSub(a: Int64, b: Int64): Int64 return sub(a, b);
	@:op(A * B) inline static function opMul(a: Int64, b: Int64): Int64 return mul(a, b);
	@:op(A / B) inline static function opDiv(a: Int64, b: Int64): Int64 return div(a, b);
	@:op(A % B) inline static function opMod(a: Int64, b: Int64): Int64 return mod(a, b);
	@:op(A & B) inline static function opAnd(a: Int64, b: Int64): Int64 return and(a, b);
	@:op(A | B) inline static function opOr(a: Int64, b: Int64): Int64 return or(a, b);
	@:op(A ^ B) inline static function opXor(a: Int64, b: Int64): Int64 return xor(a, b);
	@:op(A << B) inline static function opShl(a: Int64, b: Int): Int64 return shl(a, b);
	@:op(A >> B) inline static function opShr(a: Int64, b: Int): Int64 return shr(a, b);
	@:op(A >>> B) inline static function opUshr(a: Int64, b: Int): Int64 return ushr(a, b);
	@:op(A == B) inline static function opEq(a: Int64, b: Int64): Bool return (a : Int) == (b : Int);
	@:op(A != B) inline static function opNeq(a: Int64, b: Int64): Bool return (a : Int) != (b : Int);
	@:op(A < B) inline static function opLt(a: Int64, b: Int64): Bool return (a : Int) < (b : Int);
	@:op(A <= B) inline static function opLte(a: Int64, b: Int64): Bool return (a : Int) <= (b : Int);
	@:op(A > B) inline static function opGt(a: Int64, b: Int64): Bool return (a : Int) > (b : Int);
	@:op(A >= B) inline static function opGte(a: Int64, b: Int64): Bool return (a : Int) >= (b : Int);
}
