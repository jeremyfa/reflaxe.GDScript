package gdcompiler.preprocessors;

#if (macro || gdscript_runtime)

import haxe.macro.Type;

import reflaxe.BaseCompiler;
import reflaxe.data.ClassFuncData;
import reflaxe.preprocessors.BasePreprocessor;

/**
	Rewrites `a && b` as `a ? b : false` and `a || b` as `a ? true : b`
	BEFORE the everything-is-expression sanitizer runs.

	The sanitizer hoists non-trivial operands into temporary statements
	without preserving short-circuit semantics, so the right-hand side of a
	boolean operator could be evaluated unconditionally (breaking null
	guards and throwing property getters). If-expressions keep their
	branches conditional through the sanitizer.
**/
class ShortCircuitToIf extends BasePreprocessor {
	public function new() {}

	public function process(data: ClassFuncData, compiler: BaseCompiler): Void {
		if(data.expr != null) {
			data.setExpr(transform(data.expr));
		}
	}

	function transform(e: TypedExpr): TypedExpr {
		final mapped = haxe.macro.TypedExprTools.map(e, transform);
		return switch(mapped.expr) {
			case TBinop(OpBoolAnd, a, b): {
				{
					expr: TIf(ensureParens(a), b, boolConst(false, mapped)),
					pos: mapped.pos,
					t: mapped.t
				};
			}
			case TBinop(OpBoolOr, a, b): {
				{
					expr: TIf(ensureParens(a), boolConst(true, mapped), b),
					pos: mapped.pos,
					t: mapped.t
				};
			}
			case _: mapped;
		}
	}

	function ensureParens(e: TypedExpr): TypedExpr {
		return switch(e.expr) {
			case TParenthesis(_): e;
			case _: { expr: TParenthesis(e), pos: e.pos, t: e.t };
		}
	}

	function boolConst(value: Bool, from: TypedExpr): TypedExpr {
		return {
			expr: TConst(TBool(value)),
			pos: from.pos,
			t: from.t
		};
	}
}

#end
