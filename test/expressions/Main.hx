/**
	Expressions that GDScript can't write inline and that the compiler must
	lower into statements: increments and assignments used as values (also in
	the branches of an assigned `if` or `switch`), and blocks, ifs and
	short-circuits inside class variable initializers. Also nullable primitives
	added to a String, which GDScript refuses without a conversion.
**/
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

		// Nullable primitives added to a String
		final n: Null<Int> = nullable(3);
		final none: Null<Int> = nullable(null);
		final ratio: Null<Float> = nullable(1.5);
		final flag: Null<Bool> = nullable(true);
		check("nullable int in string", "n=" + n == "n=3" && 'n=$n' == "n=3");
		check("null int in string", "m=" + none == "m=null");
		check("nullable float and bool in string", "r=" + ratio + " f=" + flag == "r=1.5 f=true");

		var fails = 0;
		for(r in results) {
			trace(r);
			if(StringTools.startsWith(r, "FAIL")) fails++;
		}
		trace(fails == 0 ? "ALL_EXPR_TESTS_PASSED" : "EXPR_FAILURES: " + fails);
	}
}
