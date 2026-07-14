class CustomError {
    public var msg: String;
    public function new(msg: String) {
        this.msg = msg;
    }
}

class Main {
    static var results: Array<String> = [];

    static function check(label: String, cond: Bool) {
        results.push((cond ? "PASS " : "FAIL ") + label);
    }

    public static function main() {
        // 1. throw + catch Any
        var caught = false;
        try {
            throw "boom";
        } catch (e: Any) {
            caught = (e == "boom");
        }
        check("throw string, catch Any", caught);

        // 2. class instance catch dispatch
        var kind = "";
        try {
            throw new CustomError("bad");
        } catch (e: CustomError) {
            kind = "custom:" + e.msg;
        } catch (e: Any) {
            kind = "any";
        }
        check("catch class type", kind == "custom:bad");

        // 3. non-matching first catch falls through to catch-all
        var kind2 = "";
        try {
            throw 42;
        } catch (e: CustomError) {
            kind2 = "custom";
        } catch (e: Any) {
            kind2 = "any:" + e;
        }
        check("fallthrough to Any", kind2 == "any:42");

        // 4. exception crosses function calls
        var msg = "";
        try {
            level1();
        } catch (e: Any) {
            msg = "deep:" + e;
        }
        check("propagates across calls", msg == "deep:deep-error");

        // 5. return inside try
        check("return inside try", returnsInsideTry() == 7);

        // 6. break/continue inside try inside loop
        var sum = 0;
        for (i in 0...10) {
            try {
                if (i == 3) continue;
                if (i == 5) break;
                sum += i;
            } catch (e: Any) {}
        }
        check("break/continue in try", sum == 0 + 1 + 2 + 4);

        // 7. nested try
        var order = "";
        try {
            try {
                throw "inner";
            } catch (e: CustomError) {
                order += "wrong;";
            }
            order += "unreachable;";
        } catch (e: Any) {
            order += "outer:" + e + ";";
        }
        check("nested try rethrows to outer", order == "outer:inner;");

        // 8. rethrow from catch
        var out = "";
        try {
            try {
                throw "first";
            } catch (e: Any) {
                throw "second";
            }
        } catch (e: Any) {
            out = "" + e;
        }
        check("rethrow from catch", out == "second");

        // 9. loop inside try, throw from nested loop
        var v = "";
        try {
            for (i in 0...3) {
                for (j in 0...3) {
                    if (i == 1 && j == 1) throw "nested-loop";
                }
            }
        } catch (e: Any) {
            v = "" + e;
        }
        check("throw from nested loops", v == "nested-loop");

        // 10. uncaught exception in callee unwinds to caller's catch
        var observed = "";
        try {
            var r = mayThrow(true);
            observed = "no-throw:" + r;
        } catch (e: Any) {
            observed = "caught:" + e;
        }
        check("uncaught unwinds to caller catch", observed == "caught:argh");

        // 11. no exception: normal flow
        check("normal flow", mayThrow(false) == 99);

        // 12. throw in expression position (ternary-like)
        var got = "";
        try {
            var x = compute(true);
            got = "value:" + x;
        } catch (e: Any) {
            got = "threw:" + e;
        }
        check("throw in expression", got == "threw:neg");

        for (line in results) {
            trace(line);
        }
        var fails = 0;
        for (line in results) {
            if (StringTools.startsWith(line, "FAIL")) fails++;
        }
        trace(fails == 0 ? "ALL_EXC_TESTS_PASSED" : "EXC_FAILURES: " + fails);
    }

    static function level1(): Void {
        level2();
    }

    static function level2(): Void {
        throw "deep-error";
    }

    static function returnsInsideTry(): Int {
        try {
            return 7;
        } catch (e: Any) {}
        return -1;
    }

    static function mayThrow(doThrow: Bool): Int {
        if (doThrow) throw "argh";
        return 99;
    }

    static function compute(neg: Bool): Int {
        return neg ? throw "neg" : 5;
    }
}
