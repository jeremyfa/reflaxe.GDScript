package gdcompiler.preprocessors;

#if (macro || gdscript_runtime)

import haxe.macro.Type;

import reflaxe.BaseCompiler;
import reflaxe.data.ClassFuncData;
import reflaxe.preprocessors.BasePreprocessor;

using reflaxe.helpers.NullableMetaAccessHelper;

/**
	GDScript lambdas capture local variables BY VALUE at creation time, so a
	local function variable referenced from its own body (self recursion) or
	from an earlier sibling lambda (mutual recursion) is captured as null.

	This pass tags such variables with @:arrayWrap: the compiler then emits
	`var f = [func...]` and rewrites reads to `f[0]`, giving the capture
	reference semantics (Arrays are shared by reference in GDScript).
**/
class WrapRecursiveLambdas extends BasePreprocessor {
	public function new() {}

	/**
		TVar ids declared in the function body. Assignment-form wrapping only
		applies to these; parameters and outer captures are not declarations
		we can turn into arrays.
	**/
	var declaredIds: Map<Int, Bool> = [];

	var compiler: Null<gdcompiler.GDCompiler> = null;

	/**
		Lambda nesting depth each TVar was declared at.
	**/
	var declDepth: Map<Int, Int> = [];

	public function process(data: ClassFuncData, compiler: BaseCompiler): Void {
		if(data.expr != null) {
			this.compiler = cast compiler;
			declaredIds = [];
			collectDeclarations(data.expr);
			walk(data.expr);
			declDepth = [];
			scanReassignedCaptures(data.expr, 0);
		}
	}

	/**
		GDScript lambdas capture by value: a variable REASSIGNED inside a
		lambda but declared outside it (at a shallower lambda depth) needs
		array wrapping so the write reaches the original.
	**/
	function scanReassignedCaptures(e: TypedExpr, depth: Int): Void {
		switch(e.expr) {
			case TVar(tvar, init): {
				declDepth.set(tvar.id, depth);
				if(init != null) scanReassignedCaptures(init, depth);
			}
			case TFunction(tfunc): {
				scanReassignedCaptures(tfunc.expr, depth + 1);
			}
			case TBinop(OpAssign | OpAssignOp(_), lhs = { expr: TLocal(v) }, rhs): {
				markIfCapturedWrite(v, depth);
				scanReassignedCaptures(rhs, depth);
			}
			case TUnop(OpIncrement | OpDecrement, _, { expr: TLocal(v) }): {
				markIfCapturedWrite(v, depth);
			}
			case _: {
				haxe.macro.TypedExprTools.iter(e, sub -> scanReassignedCaptures(sub, depth));
			}
		}
	}

	function markIfCapturedWrite(v: TVar, depth: Int): Void {
		final dd = declDepth.get(v.id);
		if(dd != null && depth > dd && compiler != null) {
			compiler.recursiveLambdaWrapIds.set(v.id, true);
		}
	}

	function collectDeclarations(e: TypedExpr): Void {
		switch(e.expr) {
			case TVar(tvar, _): declaredIds.set(tvar.id, true);
			case _:
		}
		haxe.macro.TypedExprTools.iter(e, collectDeclarations);
	}

	function walk(e: TypedExpr): Void {
		switch(e.expr) {
			case TBlock(el): {
				processBlock(el);
				for(sub in el) walk(sub);
			}
			case _: haxe.macro.TypedExprTools.iter(e, walk);
		}
	}

	function processBlock(el: Array<TypedExpr>): Void {
		// Collect local variables assigned a lambda in this block, in
		// either form: `var f = func...` or `var f; ... f = func...`.
		final funcVars: Array<{ tvar: TVar, assignIndex: Int }> = [];
		for(i in 0...el.length) {
			switch(el[i].expr) {
				case TVar(tvar, init) if(init != null): {
					switch(init.expr) {
						case TFunction(_): funcVars.push({ tvar: tvar, assignIndex: i });
						case _:
					}
				}
				case TBinop(OpAssign, { expr: TLocal(tvar) }, rhs) if(declaredIds.exists(tvar.id)): {
					switch(rhs.expr) {
						case TFunction(_): funcVars.push({ tvar: tvar, assignIndex: i });
						case _:
					}
				}
				case _:
			}
		}
		if(funcVars.length == 0) return;

		for(fv in funcVars) {
			if(fv.tvar.meta.maybeHas(":arrayWrap")) continue;
			var needsWrap = false;

			// Self reference: the assigned lambda mentions its own variable.
			if(referencesInsideLambda(el[fv.assignIndex], fv.tvar.id)) {
				needsWrap = true;
			}

			// Forward reference: an earlier statement captured the variable
			// (typically a mutually recursive lambda) before assignment.
			if(!needsWrap) {
				for(i in 0...fv.assignIndex) {
					if(references(el[i], fv.tvar.id)) {
						needsWrap = true;
						break;
					}
				}
			}

			if(needsWrap) {
				// Registered by id on the compiler: TVar instances may be
				// copies sharing the id but not the metadata.
				if(compiler != null) {
					compiler.recursiveLambdaWrapIds.set(fv.tvar.id, true);
				}
			}
		}
	}

	/**
		True if `tvarId` is referenced from within any lambda inside `e`
		(not counting direct references outside lambdas).
	**/
	function referencesInsideLambda(e: TypedExpr, tvarId: Int): Bool {
		var found = false;
		function iter(e: TypedExpr, insideLambda: Bool) {
			if(found) return;
			switch(e.expr) {
				case TLocal(v) if(insideLambda && v.id == tvarId): found = true;
				case TFunction(tfunc): iter(tfunc.expr, true);
				case _: haxe.macro.TypedExprTools.iter(e, sub -> iter(sub, insideLambda));
			}
		}
		iter(e, false);
		return found;
	}

	function references(e: TypedExpr, tvarId: Int): Bool {
		var found = false;
		function iter(e: TypedExpr) {
			if(found) return;
			switch(e.expr) {
				case TLocal(v) if(v.id == tvarId): found = true;
				case _: haxe.macro.TypedExprTools.iter(e, iter);
			}
		}
		iter(e);
		return found;
	}
}

#end
