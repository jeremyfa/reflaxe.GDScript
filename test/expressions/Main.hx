/**
	Expressions that GDScript can't write inline and that the compiler must
	lower into statements: increments and assignments used as values (also in
	the branches of an assigned `if` or `switch`), and blocks, ifs and
	short-circuits inside class variable initializers. Also nullable primitives
	added to a String, which GDScript refuses without a conversion.
**/

/**
	A dynamic method is a class variable holding a function: its body must be
	lowered like the body of any other method.
**/
class Handler {
	final values: Map<String, String> = new Map();

	public function new() {
		values.set("k", "v");
	}

	// A loop over an iterator: a call that can throw
	function lookup(key: String): String {
		for(k in values.keys()) {
			if(k == key) return k;
		}
		return key;
	}

	public dynamic function read(key: String, callback: (String) -> Void): Void {
		final k = lookup(key);
		if(values.exists(k)) {
			callback(values.get(k));
			return;
		}
		callback(null);
	}
}

class Main {
	static var results: Array<String> = [];

	// Class variable initializers go through the same lowering as function bodies
	static final JOINED = ["a", "b", "c"].join("\n");
	static final POSTFIX_IN_INIT = {
		var n = 5;
		var i = n++;
		i * 10 + n;
	};
	static final IF_IN_INIT = [1, 2].length > 1 ? "long" : "short";
	static final SHORT_CIRCUIT_IN_INIT = [1, 2].length > 1 && [3].length == 1 ? "yes" : "no";

	// Values from a function, so that the compiler can't fold the additions
	static function nullable<T>(v: T): Null<T> {
		return v;
	}

	static function check(label: String, cond: Bool) {
		results.push((cond ? "PASS " : "FAIL ") + label);
	}

	public static function main() {
		var a = 0;
		var b = 10;
		final c = true;

		// Postfix and prefix increments as the value of an assigned if
		final v = c ? a++ : b++;
		check("postfix in if value", v == 0 && a == 1 && b == 10);
		final w = c ? ++a : --b;
		check("prefix in if value", w == 2 && a == 2 && b == 10);

		// Inside an object field (value of an if nested in an expression)
		final o = { k: c ? a++ : b++ };
		check("postfix in object field", o.k == 2 && a == 3);

		// As the value of a switch branch
		final s = switch(a) {
			case 3: a++;
			case _: b--;
		}
		check("postfix in switch value", s == 3 && a == 4 && b == 10);

		// Postfix on a float keeps the exact old value
		var f = 0.1;
		final g = c ? f++ : 0.0;
		check("postfix on float", g == 0.1 && f == 1.1);

		// An assignment used as the value of an if
		var x = 0;
		final y = c ? (x = 5) : 7;
		check("assignment in if value", y == 5 && x == 5);

		// Class variable initializers
		check("join in initializer", JOINED == "a\nb\nc");
		check("postfix in initializer", POSTFIX_IN_INIT == 56);
		check("if in initializer", IF_IN_INIT == "long");
		check("short-circuit in initializer", SHORT_CIRCUIT_IN_INIT == "yes");

		// Inlined map calls in the body of a dynamic method
		var read: Null<String> = null;
		new Handler().read("k", v -> read = v);
		check("inlined calls in a dynamic method", read == "v");

		// Nullable primitives added to a String
		final n: Null<Int> = nullable(3);
		final none: Null<Int> = nullable(null);
		final ratio: Null<Float> = nullable(1.5);
		final flag: Null<Bool> = nullable(true);
		check("nullable int in string", "n=" + n == "n=3" && 'n=$n' == "n=3");
		check("null int in string", "m=" + none == "m=null");
		check("nullable float and bool in string", "r=" + ratio + " f=" + flag == "r=1.5 f=true");

		// Control characters in string literals: written raw, some of them end
		// the GDScript literal or the line
		final controls = "a\x01b\x1Bc\x7Fd\x0Be\x0Cf";
		check("control characters in a literal", controls.length == 11
			&& controls.charCodeAt(1) == 0x01 && controls.charCodeAt(3) == 0x1B
			&& controls.charCodeAt(5) == 0x7F && controls.charCodeAt(7) == 0x0B
			&& controls.charCodeAt(9) == 0x0C);
		// A Godot string can't hold a nul character: the engine replaces it with
		// U+FFFD. The literal must still parse, and keep its length
		final nul = "x\x00y";
		check("nul character in a literal", nul.length == 3 && nul.charCodeAt(2) == "y".code);

		// Arrays and structures compare by identity, typed or not
		final arr1 = [1, 2];
		final arr2 = [1, 2];
		final arrAny1: Any = arr1;
		final arrAny2: Any = arr2;
		final sameArr: Any = arr1;
		check("typed arrays by identity", arr1 == arr1 && arr1 != arr2 && !(arr1 == arr2));
		check("dynamic arrays by identity", arrAny1 == sameArr && arrAny1 != arrAny2);
		final st1 = { k: 1 };
		final st2 = { k: 1 };
		final stAny1: Dynamic = st1;
		final stAny2: Dynamic = st2;
		final sameSt: Dynamic = st1;
		check("typed structures by identity", st1 == st1 && st1 != st2);
		check("dynamic structures by identity", stAny1 == sameSt && stAny1 != stAny2);

		// Increment and decrement of an array element: the read is a helper call,
		// which is not a valid assignment target
		final counts = [0, 0, 0];
		counts[1]++;
		++counts[2];
		counts[2]--;
		final at = 1;
		counts[at + 1]++;
		check("increment of an array element", counts[0] == 0 && counts[1] == 1 && counts[2] == 1);

		// Texts beyond ASCII as call arguments, and in the bodies of an if and
		// of a loop: the generator used to crash on them
		final accented = Std.string("été");
		check("call argument beyond ASCII", accented == "été" && Std.string("ß😀").length > 0);
		var inBody = "";
		if(accented.length > 0) inBody = Std.string("ça");
		for(i in 0...1) inBody += Std.string("ñ");
		check("bodies beyond ASCII", inBody == "çañ");

		// Float literals with an exponent
		final powers:Array<Float> = [1e0, 1e3, 2.5e2, 1E2, 1e-2];
		check("float literals with an exponent", powers[0] == 1 && powers[1] == 1000 && powers[2] == 250 && powers[3] == 100 && powers[4] == 0.01);

		// Searching an empty text, as in Haxe
		final abc = Std.string("abc");
		check("index of an empty text", abc.indexOf("") == 0 && abc.indexOf("", 2) == 2 && abc.indexOf("", 9) == 3 && abc.lastIndexOf("") == 3 && abc.lastIndexOf("", 1) == 1 && abc.indexOf("c") == 2);

		var fails = 0;
		for(r in results) {
			trace(r);
			if(StringTools.startsWith(r, "FAIL")) fails++;
		}
		trace(fails == 0 ? "ALL_EXPR_TESTS_PASSED" : "EXPR_FAILURES: " + fails);
	}
}
