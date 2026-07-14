package gdcompiler;

#if (macro || gdscript_runtime)

//import haxe.macro.Context;
import reflaxe.helpers.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

import haxe.display.Display.MetadataTarget;

import reflaxe.data.ClassVarData;
import reflaxe.data.ClassFuncArg;
import reflaxe.data.ClassFuncData;
import reflaxe.data.EnumOptionData;

import reflaxe.debug.MeasurePerformance;

import reflaxe.DirectToStringCompiler;
import reflaxe.preprocessors.implementations.RemoveSingleExpressionBlocksImpl;
import reflaxe.preprocessors.implementations.RemoveTemporaryVariablesImpl;
import reflaxe.preprocessors.implementations.everything_is_expr.EverythingIsExprSanitizer;

import gdcompiler.config.Define;
import gdcompiler.config.Meta;

import gdcompiler.subcompilers.EnumCompiler;
import gdcompiler.subcompilers.TypeCompiler;

using reflaxe.helpers.ArrayHelper;
using reflaxe.helpers.BaseTypeHelper;
using reflaxe.helpers.ClassFieldHelper;
using reflaxe.helpers.ClassTypeHelper;
using reflaxe.helpers.ExprHelper;
using reflaxe.helpers.ModuleTypeHelper;
using reflaxe.helpers.NameMetaHelper;
using reflaxe.helpers.NullableMetaAccessHelper;
using reflaxe.helpers.NullHelper;
using reflaxe.helpers.OperatorHelper;
using reflaxe.helpers.StringBufHelper;
using reflaxe.helpers.SyntaxHelper;
using reflaxe.helpers.TypedExprHelper;
using reflaxe.helpers.TypeHelper;

// ---

enum AccessMode {
	Default;
	ForceSelf;
	RemoveFieldAccess;
}

// ---

class GDCompiler extends reflaxe.DirectToStringCompiler {
	/**
		The name of the autoload GDScript file that's generated
		if necessary.
	**/
	static var autoLoadName = "HxAutoLoad";

	/**
		Enum compiler.
	**/
	var enumCompiler: EnumCompiler;

	/**
		Type compiler.
	**/
	var typeCompiler: TypeCompiler;

	/**
		Keeps track of all the classes that extend from `godot.Node`.
		Important for plugin generation.
	**/
	var pluginNodeClasses: Array<ClassType> = [];

	/**
		Keeps track of all the classes that extend from `godot.Resource`.
		Important for plugin generation.
	**/
	var pluginResourceClasses: Array<ClassType> = [];

	/**
		A stack used to track any overrides to the "self" keyword.
		If empty, "self" will be used.
	**/
	var selfStack: Array<{ selfName: String, publicOnly: Bool }> = [];

	/**
		A list of fields (using Haxe names) that should not be generated
		with `self.`. Certain circumstances in GDScript prevent this:
		 - Cannot use `self.` on a field within its own setter.
	**/
	var bypassSelfStack: Array<String> = [];

	/**
		Set to `true` when compiling an expression for a constructor.
	**/
	var compilingInConstructor: Bool = false;

	/**
		Exception lowering state.

		GDScript has no exceptions, so `throw`/`try`/`catch` are lowered to a
		"pending exception" scheme: `throw` stores the thrown value in the
		generated `HxExc` singleton and unwinds by returning a default value,
		while every statement that may throw is followed by a check that
		propagates the pending exception. `try` blocks compile to a
		single-iteration `while true:` (the only break target GDScript offers)
		so the checks can unwind to the matching catch dispatch with `break`.
	**/
	var excUsed: Bool = false;

	/**
		Default return value (as GDScript code) for each enclosing function
		being compiled. `null` entry means the function returns void.
	**/
	var excFuncStack: Array<Null<String>> = [];

	/**
		Active lowered `try` contexts within the current function.
	**/
	var excTryStack: Array<{ ctrl: String, ret: String, loopDepth: Int }> = [];

	/**
		Unique id source for lowered try-block variables.
	**/
	var excTryCounter: Int = 0;

	/**
		Number of real loops enclosing the expression currently being
		compiled, within the current function. Used to decide whether a
		lowered try's control dispatch can legally re-emit break/continue.
	**/
	var excFuncLoopDepth: Int = 0;

	static final excClassName = "HxExc";

	/**
		Classes generated in this compilation, as (Haxe dotted path, compiled
		GDScript class name, implemented interface paths) entries. Emitted
		into an HxType.gd registry that backs Type.resolveClass /
		Type.getClassName and interface checks in Std.isOfType.
	**/
	var typeRegistry: Array<{ dotted: String, compiled: String, ifaces: Array<String> }> = [];

	function excCurrentTry(): Null<{ ctrl: String, ret: String, loopDepth: Int }> {
		return excTryStack.length > 0 ? excTryStack[excTryStack.length - 1] : null;
	}

	/**
		GDScript default value for a compiled type, used to satisfy typed
		returns when unwinding. Typed builtins are non-nullable in GDScript.
	**/
	function excDefaultForType(t: Null<Type>, pos: Position): Null<String> {
		if(t == null) return "null";
		if(t.isVoid()) return null;
		final compiled = typeCompiler.compileType(t, pos);
		if(compiled == null) return "null";
		return switch(compiled) {
			case "int": "0";
			case "float": "0.0";
			case "bool": "false";
			case "String": "\"\"";
			case "StringName": "&\"\"";
			case "Dictionary": "{}";
			case _:
				if(StringTools.startsWith(compiled, "Array")) "[]";
				else "null";
		}
	}

	/**
		The line used to leave the current context when a pending exception
		must propagate: `break` out to the nearest lowered try dispatch, or
		return the function's default value.
	**/
	function excUnwindLine(): String {
		if(excCurrentTry() != null) return "break";
		return excReturnLine(null);
	}

	/**
		A `return` respecting the current function's default value.
		Pass `valueName` to return an explicit value instead.
	**/
	function excReturnLine(valueName: Null<String>): String {
		if(valueName != null) return "return " + valueName;
		final def = excFuncStack.length > 0 ? excFuncStack[excFuncStack.length - 1] : "null";
		return def == null ? "return" : "return " + def;
	}

	/**
		Compiles a `break` statement, rerouting through the lowered try
		protocol when the nearest enclosing loop is a try wrapper.
	**/
	function excEmitBreak(): String {
		final t = excCurrentTry();
		if(t != null && t.loopDepth == 0) {
			return t.ctrl + " = 1\nbreak";
		}
		return "break";
	}

	/**
		Compiles a `continue` statement, rerouting through the lowered try
		protocol when the nearest enclosing loop is a try wrapper.
	**/
	function excEmitContinue(): String {
		final t = excCurrentTry();
		if(t != null && t.loopDepth == 0) {
			return t.ctrl + " = 2\nbreak";
		}
		return "continue";
	}

	/**
		Compiles a `return` statement, rerouting through the lowered try
		protocol when inside a lowered try body.
	**/
	function excEmitReturn(compiledValue: Null<String>): String {
		final t = excCurrentTry();
		if(t != null) {
			var result = "";
			if(compiledValue != null) {
				result += t.ret + " = " + compiledValue + "\n";
			}
			result += t.ctrl + " = 3\nbreak";
			return result;
		}
		return compiledValue != null ? "return " + compiledValue : excReturnLine(null);
	}

	/**
		Returns `true` if evaluating this expression may set the pending
		exception flag. Conservative: any call or construction into compiled
		Haxe code counts. Calls to extern (native Godot) methods cannot throw
		a Haxe exception, except `Callable` invocations which may run
		compiled closures.
	**/
	function excExprCanThrow(expr: TypedExpr): Bool {
		var found = false;
		function walk(e: TypedExpr) {
			if(found) return;
			switch(e.expr) {
				case TFunction(_): // declaration only, body does not run here
				case TThrow(_): found = true;
				case TNew(_, _, el): {
					found = true;
				}
				case TCall(callee, el): {
					if(excCalleeCanThrow(callee)) {
						found = true;
					} else {
						walk(callee);
						for(a in el) walk(a);
					}
				}
				case _: haxe.macro.TypedExprTools.iter(e, walk);
			}
		}
		walk(expr);
		return found;
	}

	function excCalleeCanThrow(callee: TypedExpr): Bool {
		return switch(callee.unwrapParenthesis().expr) {
			case TField(_, FInstance(clsRef, _, cfRef) | FStatic(clsRef, cfRef)): {
				final cls = clsRef.get();
				if(!cls.isExtern) {
					true;
				} else {
					// Callable.call and friends may invoke compiled closures.
					final name = cfRef.get().name;
					cls.name == "Callable" || name == "call" || name == "callv" || name == "call_deferred";
				}
			}
			case TField(_, FEnum(_, _)): false; // enum constructor: pure data
			case _: true;
		}
	}

	/**
		Lines to append after a compiled statement to propagate pending
		exceptions (and, for loops inside lowered try bodies, control-flow
		signals that used `break` to leave inner loops).
	**/
	function excPostStatement(stmt: TypedExpr): Null<String> {
		final t = excCurrentTry();
		var inner = stmt;
		var isLoop = false;
		while(true) {
			switch(inner.expr) {
				case TMeta(_, e) | TParenthesis(e): inner = e;
				case TWhile(_, _, _) | TFor(_, _, _): isLoop = true; break;
				case _: break;
			}
		}
		final canThrow = excExprCanThrow(stmt);
		final canUnwind = excFuncStack.length > 0 || t != null;

		if(t != null && isLoop) {
			// A return/break/continue (or pending exception) inside the loop
			// only broke out of the loop itself; keep unwinding to the wrapper.
			excUsed = true;
			final cond = canThrow ? (t.ctrl + " != 0 or " + excClassName + ".active") : (t.ctrl + " != 0");
			return "if " + cond + ":\n\tbreak";
		}
		if(canThrow && canUnwind) {
			excUsed = true;
			return "if " + excClassName + ".active:\n\t" + excUnwindLine();
		}
		return null;
	}

	/**
		Compiles a statement, prepending hoisted content (e.g. multiline
		lambdas lifted out of call arguments) and appending exception
		propagation checks.
	**/
	function excCompileStatement(stmt: TypedExpr): Null<String> {
		final savedAllowed = injectionAllowed;
		final savedContent = injectionContent;
		injectionAllowed = true;
		injectionContent = [];

		final code = compileExpression(stmt);

		final pre = injectionContent;
		injectionAllowed = savedAllowed;
		injectionContent = savedContent;

		if(code == null) {
			return pre.length > 0 ? pre.join("\n") : null;
		}
		var full = pre.length > 0 ? (pre.join("\n") + "\n" + code) : code;
		final suffix = excPostStatement(stmt);
		return suffix != null ? (full + "\n" + suffix) : full;
	}

	/**
		Mirrors `DirectToStringCompiler.compileExpressionsIntoLines`, adding
		pending-exception propagation checks after each statement. Used for
		function bodies and variable initializer blocks.
	**/
	public override function compileClassVarExpr(expr: TypedExpr): String {
		final exprList = expr.unwrapBlock();
		var currentType = -1;
		final lines = [];

		injectionAllowed = true;

		for(e in exprList) {
			final newType = expressionType(e);
			if(currentType != newType) {
				if(currentType != -1) lines.push("");
				currentType = newType;
			}

			final output = compileExpression(e, true);

			final preExpr = prefixExpressionContent(e, output);
			if(preExpr != null) {
				for(p in preExpr) {
					lines.push(formatExpressionLine(p));
				}
			}

			if(output != null) {
				lines.push(formatExpressionLine(output));
				final suffix = excPostStatement(e);
				if(suffix != null) {
					lines.push(suffix);
				}
			}

			if(injectionContent.length > 0) {
				injectionContent = [];
			}
		}

		injectionAllowed = false;

		return lines.join("\n");
	}

	/**
		The GDScript source of the runtime type registry, mapping Haxe dotted
		class paths to generated Script globals and back. Backs
		Type.resolveClass / Type.getClassName.
	**/
	function typeRegistrySource(): String {
		final buf = new StringBuf();
		buf.add("class_name HxType\n\n");
		buf.add("# Runtime type registry generated by the compiler.\n\n");
		buf.add("static var _by_name: Dictionary = {}\n");
		buf.add("static var _by_script: Dictionary = {}\n");
		buf.add("static var _interfaces: Dictionary = {}\n\n\n");
		buf.add("static func _reg() -> void:\n");
		buf.add("\tif not _by_name.is_empty():\n\t\treturn\n");
		buf.add("\t_by_name = {\n");
		for(entry in typeRegistry) {
			buf.add("\t\t\"" + entry.dotted + "\": " + entry.compiled + ",\n");
		}
		buf.add("\t}\n");
		buf.add("\tfor key in _by_name:\n");
		buf.add("\t\t_by_script[_by_name[key]] = key\n");
		for(entry in typeRegistry) {
			if(entry.ifaces.length > 0) {
				final pairs = entry.ifaces.map(i -> "\"" + i + "\": true").join(", ");
				buf.add("\t_interfaces[" + entry.compiled + "] = { " + pairs + " }\n");
			}
		}
		buf.add("\n\n");
		buf.add("static func resolve(name: String) -> Variant:\n");
		buf.add("\t_reg()\n");
		buf.add("\treturn _by_name.get(name)\n\n\n");
		buf.add("static func name_of(c) -> Variant:\n");
		buf.add("\t_reg()\n");
		buf.add("\treturn _by_script.get(c)\n\n\n");
		buf.add("# Runtime `Std.isOfType`: `t` may be a Script, a builtin type\n");
		buf.add("# sentinel (&\"hx:String\", ...) or an interface sentinel.\n");
		buf.add("static func is_of_type(v, t) -> bool:\n");
		buf.add("\tif t == null:\n\t\treturn false\n");
		buf.add("\tif t is StringName:\n");
		buf.add("\t\tvar s := String(t)\n");
		buf.add("\t\tmatch s:\n");
		buf.add("\t\t\t\"hx:String\":\n\t\t\t\treturn typeof(v) == TYPE_STRING or typeof(v) == TYPE_STRING_NAME\n");
		buf.add("\t\t\t\"hx:Array\":\n\t\t\t\treturn typeof(v) == TYPE_ARRAY\n");
		buf.add("\t\t\t\"hx:Dictionary\":\n\t\t\t\treturn typeof(v) == TYPE_DICTIONARY\n");
		buf.add("\t\t\t\"hx:int\":\n\t\t\t\treturn typeof(v) == TYPE_INT\n");
		buf.add("\t\t\t\"hx:float\":\n\t\t\t\treturn typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT\n");
		buf.add("\t\t\t\"hx:bool\":\n\t\t\t\treturn typeof(v) == TYPE_BOOL\n");
		buf.add("\t\t\t\"hx:Callable\":\n\t\t\t\treturn typeof(v) == TYPE_CALLABLE\n");
		buf.add("\t\tif s.begins_with(\"hxenum:\"):\n");
		buf.add("\t\t\treturn typeof(v) == TYPE_DICTIONARY and v.get(\"_hx_enum\") == s.substr(7)\n");
		buf.add("\t\tif s.begins_with(\"hxiface:\"):\n");
		buf.add("\t\t\tif typeof(v) != TYPE_OBJECT or v == null:\n\t\t\t\treturn false\n");
		buf.add("\t\t\t_reg()\n");
		buf.add("\t\t\tvar iface := s.substr(8)\n");
		buf.add("\t\t\tvar script = v.get_script()\n");
		buf.add("\t\t\twhile script != null:\n");
		buf.add("\t\t\t\tvar ifaces = _interfaces.get(script)\n");
		buf.add("\t\t\t\tif ifaces != null and ifaces.has(iface):\n\t\t\t\t\treturn true\n");
		buf.add("\t\t\t\tscript = script.get_base_script()\n");
		buf.add("\t\t\treturn false\n");
		buf.add("\t\treturn false\n");
		buf.add("\tif typeof(v) != TYPE_OBJECT or v == null:\n\t\treturn false\n");
		buf.add("\treturn is_instance_of(v, t)\n");
		return buf.toString();
	}

	/**
		The GDScript source of the pending-exception runtime holder.
	**/
	function excRuntimeSource(): String {
		return "class_name " + excClassName + "\n\n"
			+ "# Pending-exception state for lowered Haxe try/catch/throw.\n"
			+ "# `throw` stores the value here and unwinds by returning default\n"
			+ "# values; compiled code checks `active` after each call that may\n"
			+ "# throw and keeps unwinding until a catch dispatch consumes it.\n\n"
			+ "static var val = null\n"
			+ "static var active: bool = false\n\n\n"
			+ "static func throw_val(v) -> Variant:\n"
			+ "\tval = v\n"
			+ "\tactive = true\n"
			+ "\treturn null\n";
	}

	#if generate_resource_export_list
	/**
		A list of resources preloaded by the code.
	**/
	var usedResources: Array<String> = [];
	#end

	public function new() {
		super();

		@:nullSafety(Off) final self = this;
		enumCompiler = new EnumCompiler(self);
		typeCompiler = new TypeCompiler(self);
	}

	/**
		Make sure "_" isn't a variable name.
	**/
	/**
		GDScript keywords and built-in member names that cannot be used as
		identifiers; valid in Haxe, so they get a suffix. Applied to both
		declarations and accesses so renames stay consistent across classes.
	**/
	static final gdReservedIdentifiers = [
		"and", "or", "not", "in", "is", "as", "if", "elif", "else", "for",
		"while", "match", "when", "break", "continue", "pass", "return",
		"class", "class_name", "extends", "func", "static", "const", "enum",
		"var", "signal", "await", "void", "assert", "breakpoint", "preload",
		"self", "super", "true", "false", "null", "tool",
		// Built-in Object members that subclasses cannot redefine
		"script"
	];

	public override function compileVarName(name: String, expr: Null<TypedExpr> = null, field: Null<ClassField> = null): String {
		switch(name) {
			case "_": return "__underscore__";
			case "__underscore__": throw "__underscore__ is a reserved variable name in Reflaxe/GDScript.";
			case _ if(gdReservedIdentifiers.contains(name)): return name + "_hx";
		}
		return super.compileVarName(name, expr, field);
	}

	public function hasAutoLoad() {
		return extraFileExists(autoLoadName + ".gd");
	}

	/**
		Contributes to an HxAutoLoad.gd extra file.
		The file does not get generated if no contributions are made.
	**/
	public function addToAutoLoad(content: String) {
		final filename = autoLoadName + ".gd";
		if(!hasAutoLoad()) {
			setExtraFile(filename, "extends Node\n\n");
		}
	}

	/**
		Runs at the end of compilation.
		Generates the Godot plugin if `-D generate_godot_plugin` is defined.
	**/
	public override function onCompileEnd() {
		if(excUsed) {
			setExtraFile(excClassName + ".gd", excRuntimeSource());
		}
		if(hxArrUsed) {
			setExtraFile("HxArr.gd", hxArrRuntimeSource());
		}
		// HxDyn also backs Std.string, so it is always emitted.
		setExtraFile("HxDyn.gd", hxDynRuntimeSource());
		setExtraFile("HxType.gd", typeRegistrySource());
		if(Context.defined(Define.GenerateGodotPlugin)) {
			generatePlugin();
		}
		#if generate_resource_export_list
		if(Context.defined(Define.GenerateResourceExportList)) {
			setExtraFile("resource_export_list.txt", usedResources.join(", "));
		}
		#end
	}

	/**
		Get the name of the Godot plugin's main (or "script") file.
	**/
	function getPluginScriptName(): String {
		var result = Context.definedValue(Define.GodotPluginScriptName) ?? "plugin.gd";
		if(!StringTools.contains(result, ".")) {
			result += ".gd";
		}
		return result;
	}

	/**
		Generates the content in the `plugin.cfg` file.
	**/
	function generateGodotPluginConfig(pluginScriptName: String) {
		final getD = (name) -> Context.definedValue(name);
		return '[plugin]
name="${getD(Define.GodotPluginName) ?? "Reflaxe/GDScript Output"}"
description="${getD(Define.GodotPluginDescription) ?? "Generated by Reflaxe/GDScript"}"
author="${getD(Define.GodotPluginAuthor) ?? ""}"
version="${getD(Define.GodotPluginVersion) ?? ""}"
script="$pluginScriptName"
';
	}

	/**
		Generates the content for the plugin's main (or "script") file.
	**/
	function generatePluginScriptContent(): String {
		final enterTreeLines = [];
		final exitTreeLines = [];

		if(hasAutoLoad()) {
			enterTreeLines.push('add_autoload_singleton(AUTOLOAD_NAME, "${autoLoadName + ".gd"}")');
			exitTreeLines.push('remove_autoload_singleton(AUTOLOAD_NAME)');
		}

		for(cls in pluginNodeClasses) {
			// Guaranteed to have super class if in `pluginNodeClasses`.
			final args = [
				'"${cls.name}"',
				'"${cls.superClass.trustMe().t.get().name}"',
				'preload("${getGDOutputPath(cls)}")',
				'preload("${cls.meta.extractStringFromFirstMeta(Meta.Icon) ?? "res://icon.svg"}")'
			];
			enterTreeLines.push('add_custom_type(${args.join(", ")})');
			exitTreeLines.push('remove_custom_type("${cls.name}")');
		}

		for(cls in pluginResourceClasses) {
			// Guaranteed to have super class if in `pluginResourceClasses`.
			final args = [
				'"${cls.name}"',
				'"${cls.superClass.trustMe().t.get().name}"',
				'preload("${getGDOutputPath(cls)}")',
				'preload("${cls.meta.extractStringFromFirstMeta(Meta.Icon) ?? "res://icon.svg"}")'
			];
			enterTreeLines.push('add_custom_type(${args.join(", ")})');
			exitTreeLines.push('remove_custom_type("${cls.name}")');
		}

		return '@tool
extends EditorPlugin

const AUTOLOAD_NAME = "${autoLoadName}"

func _enter_tree():
${enterTreeLines.length > 0 ? enterTreeLines.join("\n").tab() : "\tpass"}

func _exit_tree():
${exitTreeLines.length > 0 ? exitTreeLines.join("\n").tab() : "\tpass"}
';
	}

	/**
		Generates the Godot plugin for the output GDScript files.
		This is done by generating a `plugin.cfg` file its behavior code in `plugin.gd`.

		(`plugin.gd`'s filename can be changed using `-D godot_plugin_script_name`).
	**/
	function generatePlugin() {
		final pluginScriptName = getPluginScriptName();
		setExtraFile("plugin.cfg", generateGodotPluginConfig(pluginScriptName));
		setExtraFile(pluginScriptName, generatePluginScriptContent());
	}

	/**
		Returns `true` if the `ClassType` is `godot.Node`.
		
		TODO: Might be obsolete, so maybe delete?
	**/
	function isGodotNode(t: ClassType) {
		return if(t.isExtern && t.pack.length == 1 && t.pack[0] == "godot" && t.name == "Node") {
			true;
		} else if(t.superClass != null) {
			isGodotNode(t.superClass.t.get());
		} else {
			false;
		}
	}

	function extendsFrom(t: ClassType, metadata: String): Bool {
		if(t.superClass == null) {
			return false;
		}

		final parent = t.superClass.t.get();
		if(parent.meta.maybeHas(":generated_godot_api") && parent.meta.maybeHas(metadata)) {
			final entries = parent.meta.maybeExtract(metadata);

			// Check if the first parameter of the metadata is `true`.
			for(e in entries) {
				switch(e.params) {
					case [macro true]: return true;
					case _:
				}
			}
		}

		return extendsFrom(parent, metadata);
	}

	function extendsFromNode(t: ClassType): Bool {
		return extendsFrom(t, ":is_node");
	}

	function extendsFromResource(t: ClassType): Bool {
		return extendsFrom(t, ":is_resource");
	}

	/**
		Ignore interfaces.
	**/
	public override function shouldGenerateClass(cls: ClassType): Bool {
		return !cls.isInterface && super.shouldGenerateClass(cls);
	}

	public function compileClassImpl(classType: ClassType, varFields: Array<ClassVarData>, funcFields: Array<ClassFuncData>): Null<String> {
		#if (eval && reflaxe_gdscript_measure)
		final classMeasure = new reflaxe.debug.MeasurePerformance();
		#end

		final variables = [];
		final functions = [];
		final staticVariables = [];
		final className = classType.name;
		final isWrapper = classType.hasMeta(Meta.Wrapper);
		final isWrapPublicOnly = classType.hasMeta(Meta.WrapPublicOnly);

		var header = new StringBuf();
	
		// ----------------------
		// @:icon
		if(classType.meta.has(Meta.Icon)) {
			final iconPath = classType.meta.extractStringFromFirstMeta(Meta.Icon);
			if(iconPath != null) {
				header.addMulti("@icon(\"", iconPath, "\")");
			} else {
				Context.error("Icon path required.", classType.meta.getFirstPosition(Meta.Icon) ?? classType.pos);
			}
		}

		// ----------------------
		// Class metadata string
		final clsMeta = compileMetadata(classType.meta, MetadataTarget.Class);
		if(clsMeta != null) {
			header.add(StringTools.trim(clsMeta) + "\n");
		}

		// ----------------------
		// Wrapper mode
		if(isWrapper) { // Wrapper only exists to host code, should not be treated like node itself
			header.add("extends Object\n");
		} else if(classType.superClass != null) {
			header.add("extends " + typeCompiler.compileClassName(classType.superClass.t.get()) + "\n");
		}

		// ----------------------
		// Class name
		header.addMulti("class_name ", typeCompiler.compileClassName(classType));

		// Add "_GD" to the end of class name for wrapper classes.
		if(isWrapper) {
			header.add("_GD");
		}

		header.add("\n\n");

		// ----------------------
		// VARIABLES
		for(v in varFields) {
			#if (eval && reflaxe_gdscript_measure)
			final varMeasure = new reflaxe.debug.MeasurePerformance();
			#end
			final field = v.field;

			// ----------------------
			// Do not generate extern variables
			if(field.isExtern || field.hasMeta(":extern") || field.hasMeta(":gd_extern")) {
				continue;
			}

			// ----------------------
			// Name of variable
			final name: String = if(field.hasMeta(Meta.KeepName)) {
				field.name;
			} else {
				field.meta.extractStringFromFirstMeta(Meta.NativeName) ?? compileVarName(field.name, null, field);
			}

			// ----------------------
			// The GDScript expression string override provided by metadata
			var overrideExpression = null;

			// ----------------------
			// @:onready
			var isOnReady = false;
			if(!v.isStatic && field.hasMeta(Meta.OnReady) && isGodotNode(classType)) {
				isOnReady = true;

				switch(field.meta.extractExpressionsFromFirstMeta(Meta.OnReady)) {
					case [macro val = $expr]: {
						overrideExpression = expr.getConstString() + ";";
					}
					case [macro node = $expr]: {
						overrideExpression = "$" + expr.getConstString() + ";";
					}
					case #if gdscript_snake_case [macro maybe_node = $expr] #else [macro maybeNode = $expr] #end: {
						overrideExpression = "get_node_or_null(\"" + expr.getConstString() + "\");";
					}
					case []: {
						// No arguments is allowed but doesn't do anything...
					}
					case _: {
						final maybeNodeName = #if gdscript_snake_case "maybe_node" #else "maybeNode" #end;
						Context.error("@:onready should have no arguments or one argument of format: `val = \"gdscript_expr\"`, `node = \"Node/Path\"`, or `" + maybeNodeName + " = \"Node/Path\"`.", field.pos);
					}
				}
			}

			// @:const
			var isConst = false;
			if(field.hasMeta(Meta.Const)) {
				isConst = true;

				switch(field.meta.extractExpressionsFromFirstMeta(Meta.Const)) {
					case [macro preload = $expr]: {
						final path = expr.getConstString();
						#if generate_resource_export_list
						usedResources.push(path);
						#end
						overrideExpression = "preload(\"" + path + "\");";
					}
					case []: {
						// No arguments is allowed but doesn't do anything...
					}
					case _: {
						Context.error("@:const should have no arguments or one argument of format: `preload = \"Resource/Path.tres\"`.", field.pos);
					}
				}
			}

			// ----------------------
			// Expression assigned to variable
			var initHelper: Null<String> = null;
			final gdScriptVal = if(overrideExpression != null) {
				overrideExpression;
			} else {
				final e = field.expr() ?? v.findDefaultExpr();
				if(e != null && !e.isStaticField("gdscript.Syntax", "NoAssign", true)) {
					// Do quick and dirty optimizations for "block-like" variable assignments.
					// TODO: Incorporate as feature in Reflaxe.
					final tvr = new RemoveTemporaryVariablesImpl(AllVariables, e, new Map());
					final simplified = RemoveSingleExpressionBlocksImpl.process(tvr.fixTemporaries());

					var compiled = compileClassVarExpr(simplified);
					if(compiled.indexOf("\n") >= 0) {
						// Multi-statement initializer: GDScript variable
						// initializers are single expressions, so compile the
						// original block into a generated init function whose
						// last expression becomes the return value.
						final helperName = "_hx_init_" + name;
						final stmts = e.unwrapBlock().copy();
						final last = stmts.length > 0 ? stmts.pop() : null;
						final body = new StringBuf();
						for(s in stmts) {
							final c = excCompileStatement(s);
							if(c != null) body.add(c + "\n");
						}
						body.add("return " + (last != null ? compileExpressionOrError(last) : "null"));
						initHelper = (v.isStatic ? "static " : "") + "func " + helperName + "():\n" + body.toString().tab();
						compiled = helperName + "()";
					}
					compiled;
				} else {
					"";
				}
			}

			// ----------------------
			// Metadata string
			final meta = compileMetadata(field.meta, MetadataTarget.ClassField) ?? "";
			final meta = if(isOnReady) { "@onready " + meta; } else { meta; }

			final declBuffer = new StringBuf();

			declBuffer.add(meta);
			if(isConst) {
				declBuffer.add("const ");
			} else {
				if(v.isStatic) {
					declBuffer.add("static ");
				}
				declBuffer.add("var ");
			}
			declBuffer.add(name);

			#if !gdscript_untyped
			final compiledType = typeCompiler.compileType(v.field.type, v.field.pos, v.field.hasMeta(":export"));
			if(compiledType != null) {
				declBuffer.addMulti(": ", compiledType.trustMe());
			}
			#end

			if(gdScriptVal.length > 0) {
				declBuffer.addMulti(" = ", gdScriptVal);
			}

			function getFunctionContent(originalFieldHaxeName: String, setOrGetFunctionName: Null<String>): Null<{ data: ClassFuncData, content: String }> {
				if(setOrGetFunctionName != null) {
					var desiredFuncField = null;
					for(f in funcFields) {
						if(f.field.name == setOrGetFunctionName) {
							desiredFuncField = f;
							break;
						}
					}

					if(desiredFuncField != null && desiredFuncField.expr != null) {
						bypassSelfStack.push(originalFieldHaxeName);
						final result = {
							data: desiredFuncField,
							content: compileClassFuncExpr(desiredFuncField.expr)
						};
						bypassSelfStack.pop();
						return result;
					}
				}
				return null;
			}

			var getContent = null;
			if(field.hasMeta(Meta.Get)) {
				getContent = getFunctionContent(field.name, field.meta.extractIdentifierFromFirstMeta(Meta.Get, 0));
			}
			var setContent = null;
			if(field.hasMeta(Meta.Set)) {
				setContent = getFunctionContent(field.name, field.meta.extractIdentifierFromFirstMeta(Meta.Set, 0));
			}

			if(getContent != null || setContent != null) {
				declBuffer.add(":\n");
				if(getContent != null) {
					declBuffer.add("\tget:\n");
					declBuffer.add(getContent.content.tab(2));
					if(setContent != null) declBuffer.add("\n");
					funcFields.remove(getContent.data);
				}
				if(setContent != null && setContent.data.args.length > 0) {
					declBuffer.addMulti("\tset(", setContent.data.args[0].getName(), "):\n");
					declBuffer.add(setContent.content.tab(2));
					funcFields.remove(setContent.data);
				}
			}

			(v.isStatic ? staticVariables : variables).push(declBuffer.toString());
			if(initHelper != null) {
				functions.push(initHelper);
			}

			#if (eval && reflaxe_gdscript_measure)
			varMeasure.measure("Reflaxe " + classType.name + "." + v.field.name + " compiled in %MILLI% milliseconds");
			#end
		}

		if(isWrapper) {
			variables.push("var wrapped_self");
		}

		// ----------------------
		// FUNCTIONS
		for(f in funcFields) {
			#if (eval && reflaxe_gdscript_measure)
			final funcMeasure = new reflaxe.debug.MeasurePerformance();
			#end

			final field = f.field;

			// ----------------------
			// Do not generate extern functions
			if(field.isExtern || field.hasMeta(":extern") || field.hasMeta(":gd_extern")) {
				continue;
			}

			final isConstructor = field.name == "new";
			final wrapField = isWrapper && (!isWrapPublicOnly || field.isPublic);
			final isSignal = field.hasMeta(Meta.Signal);

			// ----------------------
			// Name of function
			final name: String = if(isConstructor) {
				"_init";
			} else {
				var result = null;
				if(field.hasMeta(Meta.KeepName)) {
					result = field.name;
				} else if(field.hasMeta(Meta.NativeName)) {
					result = field.meta.extractStringFromFirstMeta(Meta.NativeName);
				}
				if(result == null) {
					final varName = compileVarName(field.name);
					
					// Prepend "wrap_" to prevent conflicts with virtuals like "_ready" and "_process".
					if(wrapField) {
						"wrap_" + varName;
					} else {
						varName;
					}
				} else {
					result;
				}
			}

			// ----------------------
			// Metadata string
			final meta = compileMetadata(field.meta, MetadataTarget.ClassField) ?? "";

			if(f.kind == MethDynamic) {
				// ----------------------
				// Reassignable function
				final e = field.expr();
				final callable = e == null ? "func():\n\tpass" : compileClassVarExpr(e);

				final funcDeclaration = new StringBuf();
				funcDeclaration.add(meta);
				if(f.isStatic) {
					funcDeclaration.add("static ");
				}
				funcDeclaration.addMulti("var ", name, " = ", callable);

				(f.isStatic ? staticVariables : variables).push(funcDeclaration.toString());
			} else {
				// ----------------------
				// Normal function
				final args = f.args;
				final wrapperSelfName = !isWrapper ? "" : (classType.meta.extractStringFromFirstMeta(Meta.Wrapper) ?? (wrapField ? "_self" : "wrapped_self"));

				final funcDeclaration = new StringBuf();
				funcDeclaration.add(meta);
				if(f.isStatic) {
					funcDeclaration.add("static ");
				}
				funcDeclaration.add(isSignal ? "signal " : "func ");
				funcDeclaration.add(name);
				funcDeclaration.add("(");
				if(wrapField) {
					funcDeclaration.add(wrapperSelfName);
					if(args.length > 0) {
						funcDeclaration.add(",");
					}
				}

				funcDeclaration.add(enforceArgumentOrder(args.map(a -> compileFunctionArgument(a, field.pos))).join(", "));
				funcDeclaration.add(")");

				if(!isSignal) {
					#if !gdscript_untyped
					final returnType = typeCompiler.compileType(f.ret, field.pos);
					if(returnType != null) {
						funcDeclaration.addMulti(" -> ", returnType);
					}
					#end

					funcDeclaration.add(":\n");

					var gdScriptVal = if(f.expr != null) {
						if(isWrapper) {
							selfStack.push({
								selfName: wrapperSelfName,
								publicOnly: isWrapPublicOnly
							});
						}

						var expr = f.expr;

						if(isConstructor) {
							compilingInConstructor = true;

							// Note: extractPreconstructorFieldAssignments is
							// deliberately NOT used here. It strips leading
							// `this.field = value` assignments from the
							// constructor whenever the field has a default,
							// but the value may depend on constructor
							// arguments (`this.id = id`), which cannot move
							// to a field initializer; the assignment was
							// silently lost.
						}

						// Compile function
						#if (eval && reflaxe_gdscript_measure)
						final me = new MeasurePerformance();
						#end

						// Exception lowering context: default return value for
						// unwinds, isolated try state per function body.
						final funcDefault = isConstructor ? null : excDefaultForType(f.ret, field.pos);
						excFuncStack.push(funcDefault);
						final savedTryStack = excTryStack;
						final savedTryCounter = excTryCounter;
						final savedLoopDepth = excFuncLoopDepth;
						excTryStack = [];
						excTryCounter = 0;
						excFuncLoopDepth = 0;

						// Local scope tracking: parameters seed the root scope.
						final savedScopes = scopeNameStack;
						final savedRenames = localRenames;
						scopeNameStack = [[]];
						localRenames = new Map();
						for(a in args) {
							declareNameInScope(compileVarName(a.getName()));
						}

						var result = compileClassFuncExpr(expr).tab();

						scopeNameStack = savedScopes;
						localRenames = savedRenames;

						// GDScript requires all code paths of a typed function
						// to return; lowered throws and complex branches can
						// end without one, so add a trailing default return.
						if(funcDefault != null && !endsWithRootReturn(result, 1)) {
							result += "\n\treturn " + funcDefault;
						}

						excFuncStack.pop();
						excTryStack = savedTryStack;
						excTryCounter = savedTryCounter;
						excFuncLoopDepth = savedLoopDepth;

						#if (eval && reflaxe_gdscript_measure)
						me.measure("expr is %MILLI%");
						#end

						if(isConstructor) {
							compilingInConstructor = false;
						}

						if(isWrapper) {
							selfStack.pop();
						}

						// Setup `wrapped_self`
						if(isWrapper && isConstructor) {
							result = "\tself.wrapped_self = _self\n" + result;
						}

						// Use "pass" if function empty
						if(StringTools.trim(result).length == 0) {
							getEmptyFunctionContent(f);
						} else {
							result;
						}
					} else {
						getEmptyFunctionContent(f);
					}

					funcDeclaration.add(gdScriptVal);

				}
				
				functions.push(funcDeclaration.toString());
			}

			#if (eval && reflaxe_gdscript_measure)
			funcMeasure.measure("Reflaxe " + classType.name + "." + f.field.name + " compiled in %MILLI% milliseconds");
			#end
		}

		// Empty classes still need a file: other classes may extend them,
		// reference them in is-checks, or look them up through the type
		// registry. Emit a stub body instead of skipping.
		if(staticVariables.length <= 0 && variables.length <= 0 && functions.length <= 0) {
			functions.push("func _hx_empty() -> void:\n\tpass");
		}

		// TODO - Try this again after Godot beta??
		// Possible bug with GDScript 2.0 beta at the moment, but static
		// functions don't work unless there's a constructor defined.
		// So a blank GDScript constructor is created if one does not exist.
		if(classType.constructor == null) {
			functions.insert(0, "func _init() -> void:\n\tpass");
		}

		// Record the class in the runtime type registry (HxType) so
		// Type.resolveClass / Type.getClassName and interface checks work
		// at runtime.
		if(!isWrapper) {
			final dotted = classType.pack.length > 0
				? classType.pack.join(".") + "." + classType.name
				: classType.name;
			final ifaceNames: Array<String> = [];
			function collectIfaces(ct: ClassType) {
				for(iref in ct.interfaces) {
					final it = iref.t.get();
					final idotted = it.pack.length > 0 ? it.pack.join(".") + "." + it.name : it.name;
					if(!ifaceNames.contains(idotted)) {
						ifaceNames.push(idotted);
						collectIfaces(it);
					}
				}
			}
			collectIfaces(classType);
			typeRegistry.push({ dotted: dotted, compiled: typeCompiler.compileClassName(classType), ifaces: ifaceNames });
		}

		// Check if extends from Node or Resource
		if(!classType.hasMeta(Meta.DontAddToPlugin)) {
			if(extendsFromNode(classType)) {
				pluginNodeClasses.push(classType);
			}
			if(extendsFromResource(classType)) {
				pluginResourceClasses.push(classType);
			}
		}

		// Put everything together
		final gdscriptContent = {
			var result = new StringBuf();

			result.add(header);

			if(staticVariables.length > 0) {
				result.add(staticVariables.join("\n") + "\n\n");
			}

			if(variables.length > 0) {
				result.add(variables.join("\n") + "\n\n");
			}

			if(functions.length > 0) {
				result.add(functions.join("\n\n") + "\n\n");
			}

			StringTools.trim(result.toString()) + "\n\n";
		}

		final path = getPathForBaseType(classType);

		// Generate file
		setExtraFile(path, gdscriptContent);

		#if (eval && reflaxe_gdscript_measure)
		classMeasure.measure("Reflaxe " + classType.name + " compiled in %MILLI% milliseconds");
		#end

		return null;
	}

	function getEmptyFunctionContent(data: ClassFuncData): String {
		if(data.ret.isVoid()) {
			return "\tpass";
		}

		if(data.ret.isBool()) {
			return "\treturn false";
		}

		if(data.ret.isNumberType()) {
			return "\treturn 0;";
		}

		return "\treturn null";
	}

	function getGDOutputPath(baseType: BaseType) {
		// File names must be unique across packages: globalName() drops the
		// package for module main types, so haxe.Json and loreline.Json
		// would both write Json.gd, one overwriting the other. Qualify with
		// the package (matching compiled class names).
		final prefix = Context.definedValue("gdscript_class_prefix") ?? "";
		var path = prefix + (baseType.pack.length > 0 ? baseType.pack.join("_") + "_" : "") + baseType.globalName() + ".gd";
		#if gdscript_output_dirs
		if(baseType.pack.length > 0) {
			#if !gdscript_always_packages_in_output_filenames
			path = baseType.name + ".gd";
			#end
			path = baseType.pack.join("/") + "/" + path;
		}
		#end
		return path;
	}

	function compileFunctionArgument(arg: ClassFuncArg, pos: Position) {
		final result = new StringBuf();
		result.add(compileVarName(arg.getName()));
		
		#if !gdscript_untyped
		final type = typeCompiler.compileType(arg.type, pos);
		if(type != null) {
			result.addMulti(": ", type);
		}
		#end

		if(arg.expr != null) {
			final valueCode = compileExpression(arg.expr);
			if(valueCode != null) {
				result.addMulti(" = ", valueCode);
			}
		}

		return result.toString();
	}

	function getNativeMetaString(metaAccess: Null<MetaAccess>) {
		var result = "";
		final nativeMeta = metaAccess.extractNativeMeta();
		if(nativeMeta != null) {
			for(m in nativeMeta) {
				result += "@" + m + "\n";
			}
		}
		return result;
	}

	function getPathForBaseType(baseType: BaseType): String {
		// @:outputFile(path: String)
		var path = if(baseType.hasMeta(Meta.OutputFile)) {
			final outputFilePath = baseType.meta.extractStringFromFirstMeta(Meta.OutputFile);
			if(outputFilePath == null) {
				final msg = "@:outputFile requires a String path for the first argument.";
				Context.error(msg, baseType.meta.getFirstPosition(Meta.OutputFile) ?? baseType.pos);
			}
			outputFilePath;
		} else {
			null;
		}

		// Default name
		if(path == null) {
			path = getGDOutputPath(baseType);
		}

		return path;
	}

	public function compileEnumImpl(enumType: EnumType, options: Array<EnumOptionData>): Null<String> {
		enumCompiler.compile(enumType, options, getPathForBaseType(enumType));
		return null;
	}
  
	public function compileExpressionImpl(expr: TypedExpr, isTopLevel: Bool): Null<String> {
		var result = new StringBuf();
		switch(expr.expr) {
			case TConst(constant): {
				result.add(constantToGDScript(constant));
			}
			case TLocal(v): {
				final renamed = localRenames.get(v.id);
				result.add(renamed != null ? renamed : compileVarName(v.name, expr));
				if(isArrayWrapped(v)) {
					result.add("[0]");
				}
			}
			case TIdent(s): {
				result.add(compileVarName(s, expr));
			}
			case TArray(e1, e2): {
				// Haxe array reads return null out of bounds; GDScript errors.
				if(isHaxeArrayType(e1.t)) {
					hxArrUsed = true;
					result.addMulti("HxArr.get_at(", compileExpressionOrError(e1), ", ", compileExpressionOrError(e2), ")");
				} else {
					result.addMulti(compileExpressionOrError(e1), "[", compileExpressionOrError(e2), "]");
				}
			}
			case TBinop(OpAssign, { expr: TField(e1, FAnon(classFieldRef)) }, e2): {
				var gdExpr1 = compileExpressionOrError(e1);
				var gdExpr2 = compileExpressionOrError(e2);
				hxDynUsed = true;
				result.add("HxDyn.set_field(" + gdExpr1 + ", \"" + classFieldRef.get().name + "\", " + gdExpr2 + ")");
			}
			case TBinop(op, e1, e2): {
				result.add(binopToGDScript(op, e1, e2));
			}
			case TField(e, fa): {
				result.add(fieldAccessToGDScript(e, fa));
			}
			case TTypeExpr(m): {
				result.add(compileTypeExprValue(m, expr.pos));
			}
			case TParenthesis(e): {
				final gdScript = compileExpressionOrError(e);
				final expr = if(!EverythingIsExprSanitizer.isBlocklikeExpr(e)) {
					"(" + gdScript + ")";
				} else {
					gdScript;
				}
				result.add(expr);
			}
			case TObjectDecl(fields): {
				result.add("{\n");
				for(i in 0...fields.length) {
					final field = fields[i];
					result.addMulti("\t\"", field.name, "\": ");
					result.add(compileExpression(field.expr));
					if(i < fields.length - 1) {
						result.add(",");
					}
					result.add("\n"); 
				}
				result.add("}");
			}
			case TArrayDecl(el): {
				final compiledType = isTopLevel ? null : typeCompiler.compileType(expr.t, expr.pos);
				if(compiledType == null) {
					result.add("[");
					result.add(el.map(e -> compileExpression(e)).join(", "));
					result.add("]");
				} else {
					result.add("([");
					result.add(el.map(e -> compileExpression(e)).join(", "));
					result.add("] as ");
					result.add(compiledType);
					result.add(")");
				}
			}
			case TCall(e, el): {
				final isEmptyConstructorSuperCall =  switch(e.unwrapParenthesis().expr) {
					case TConst(TSuper) if(compilingInConstructor && el.length == 0): true;
					case _: false;
				}

				if(!isEmptyConstructorSuperCall) {
					result.add(callToGDScript(e, el, expr));
				}
			}
			case TNew(classTypeRef, _, el): {
				result.add(newToGDScript(classTypeRef, expr, el));
			}
			case TUnop(op, postFix, e): {
				result.add(unopToGDScript(op, e, postFix));
			}
			case TFunction(tfunc): {
				result.add("func(");
				final compiledArgs = [];
				for(i in 0...tfunc.args.length) {
					final arg = tfunc.args[i];
					final reflaxeArg = new ClassFuncArg(i, arg.v.t, false, arg.v.name, arg.v.meta, arg.value, arg.v);
					compiledArgs.push(compileFunctionArgument(reflaxeArg, expr.pos));
				}
				result.add(enforceArgumentOrder(compiledArgs).join(", "));
				result.add(")");

				#if !gdscript_untyped
				final type = typeCompiler.compileType(tfunc.t, expr.pos);
				if(type != null) {
					result.addMulti(" -> ", type);
				}
				#end

				result.add(":\n");

				// Exception lowering context: closures unwind with their own
				// return default and never share the enclosing try state.
				final closureDefault = excDefaultForType(tfunc.t, expr.pos);
				excFuncStack.push(closureDefault);
				final savedTryStack = excTryStack;
				final savedTryCounter = excTryCounter;
				final savedLoopDepth = excFuncLoopDepth;
				excTryStack = [];
				excTryCounter = 0;
				excFuncLoopDepth = 0;

				// Closures see enclosing locals (captures), so the name scope
				// stack carries over; parameters join a nested scope.
				pushNameScope();
				for(arg in tfunc.args) {
					declareNameInScope(compileVarName(arg.v.name));
				}

				var closureBody = toIndentedScope(tfunc.expr).toString();

				popNameScope();
				if(closureDefault != null && !endsWithRootReturn(closureBody, 1)) {
					closureBody += "\n\treturn " + closureDefault;
				}
				result.add(closureBody);

				excFuncStack.pop();
				excTryStack = savedTryStack;
				excTryCounter = savedTryCounter;
				excFuncLoopDepth = savedLoopDepth;
			}
			case TVar(tvar, maybeExpr): {
				result.add("var ");
				result.add(declareLocal(tvar.id, compileVarName(tvar.name, expr)));
				// Array-wrapped variables declared without an initializer
				// still need their array container.
				if(maybeExpr == null && isArrayWrapped(tvar)) {
					result.add(" = [null]");
				}
				if(maybeExpr != null && !maybeExpr.isStaticField("gdscript.Syntax", "NoAssign", true)) {
					final e = compileExpressionOrError(maybeExpr);
					if(isArrayWrapped(tvar)) {
						result.addMulti(" = [", e, "]");	
					} else {
						#if !gdscript_untyped
						final compiledType = typeCompiler.compileType(tvar.t, expr.pos);
						if(compiledType != null) {
							result.addMulti(": ", compiledType);
						}
						#end

						result.addMulti(" = ", e);
					}
				}
			}
			case TBlock(el): {
				result.add("if true:\n");

				if(el.length > 0) {
					result.add(
						el
						.map(e -> excCompileStatement(e))
						.filter(e -> e != null)
						.map(e -> e.trustMe().tab())
						.join("\n")
					);
				} else {
					result.add("\tpass");
				}
			}
			case TFor(tvar, iterExpr, blockExpr): {
				final iterCode = compileExpressionOrError(iterExpr);
				result.addMulti(
					"for ", declareLocal(tvar.id, compileVarName(tvar.name)), " in ", iterCode, ":\n"
				);
				final t = excCurrentTry();
				if(t != null) t.loopDepth++;
				excFuncLoopDepth++;
				result.add(toIndentedScope(blockExpr));
				excFuncLoopDepth--;
				if(t != null) t.loopDepth--;
			}
			case TIf(econd, ifExpr, elseExpr): {
				result.addMulti("if ", compileExpressionOrError(econd), ":\n");
				result.add(toIndentedScope(ifExpr));
				if(elseExpr != null) {
					result.add("\n");
					result.add("else:\n");
					result.add(toIndentedScope(elseExpr));
				}
			}
			case TWhile(econd, blockExpr, normalWhile): {
				final t = excCurrentTry();
				if(normalWhile) {
					final gdCond = compileExpressionOrError(econd);
					result.addMulti("while ", gdCond, ":\n");
					if(t != null) t.loopDepth++;
					excFuncLoopDepth++;
					result.add(toIndentedScope(blockExpr));
					excFuncLoopDepth--;
					if(t != null) t.loopDepth--;
				} else {
					if(t != null) t.loopDepth++;
					excFuncLoopDepth++;
					final gdCond = compileExpressionOrError({
						expr: TUnop(Unop.OpNot, false, econd),
						pos: econd.pos,
						t: econd.t,
					});
					result.add("while true:\n");
					result.add(toIndentedScope(blockExpr));
					result.addMulti("\n\tif ", gdCond, ":\n");
					result.add("\t\tbreak");
					excFuncLoopDepth--;
					if(t != null) t.loopDepth--;
				}
			}
			case TSwitch(e, cases, edef): {
				// Check if this is a switch on an extern enum...
				final externEnumType = switch(e.unwrapParenthesis().expr) {
					case TEnumIndex(e1): {
						switch(e1.t) {
							case TEnum(_.get() => e, _) if(e.isReflaxeExtern()): e;
							case _: null;
						}
					}
					case _: null;
				}

				result.addMulti("match ", compileExpressionOrError(e), ":");
				for(c in cases) {
					result.add("\n\t");
					result.add(c.values.map(function(v: TypedExpr) {
						// If the switch expression is an extern enum,
						// convert the "Haxe" enum indexes to the name.
						//
						// This is because the Haxe indexes do not match the
						// number values for the Godot extern enums.
						if(externEnumType != null) {
							switch(v.expr) {
								case TConst(TInt(index)): {
									return externEnumType.names[index];
								}
								case _:
							}
						}

						return compileExpressionOrError(v);
					}).join(", "));
					result.add(":\n");
					result.add(toIndentedScope(c.expr).toString().tab());
				}
				if(edef != null) {
					result.add("\n\t_:\n");
					result.add(toIndentedScope(edef).toString().tab());
				}
			}
			case TTry(e, catches): {
				result.add(compileTryToGDScript(e, catches));
			}
			case TReturn(maybeExpr): {
				if(excTryStack.length > 0) {
					result.add(excEmitReturn(maybeExpr != null ? compileExpression(maybeExpr) : null));
				} else {
					result.add("return");
					if(maybeExpr != null) {
						result.add(" ");
						result.add(compileExpression(maybeExpr));
					}
				}
			}
			case TBreak: {
				result.add(excEmitBreak());
			}
			case TContinue: {
				result.add(excEmitContinue());
			}
			case TThrow(thrownExpr): {
				// Store the pending exception; the statement-level check right
				// after this expression performs the actual unwind. Compiling
				// as a call keeps this valid in both statement and value position.
				excUsed = true;
				result.addMulti(excClassName, ".throw_val(", compileExpressionOrError(thrownExpr), ")");
			}
			case TCast(expr, maybeModuleType): {
				final hasModuleType = maybeModuleType != null;
				if(hasModuleType) {
					result.add("(");
				}
				result.add(compileExpressionOrError(expr));
				if(hasModuleType) {
					final typeCode = typeCompiler.compileType(TypeHelper.fromModuleType(maybeModuleType.trustMe()), expr.pos);
					result.addMulti(" as ", typeCode ?? "Variant", ")");
				}
			}
			case TMeta({ name: _ => Meta.Await }, expr): {
				result.addMulti("await ", compileExpressionOrError(expr));
			}
			case TMeta(_, expr): {
				result.add(compileExpressionOrError(expr));
			}
			case TEnumParameter(expr, enumField, index): {
				result.add(compileExpressionOrError(expr));
				switch(enumField.type) {
					case TFun(args, _): {
						if(index < args.length) {
							result.addMulti(".", args[index].name);
						}
					}
					case _:
				}
			}
			case TEnumIndex(expr): {
				final kind = switch(expr.t) {
					case TEnum(_.get() => e, _): {
						if(e.isReflaxeExtern()) {
							GDScriptEnum;
						} else {
							enumCompiler.getCompileKind(e);
						}
					}
					case _: AsDictionary;
				}

				final expression = compileExpressionOrError(expr);
				switch(kind) {
					case GDScriptEnum: {
						result.addMulti("((", expression, " as Variant) as int)");
					}
					case AsInt: {
						result.add(expression);
					}
					case AsDictionary: {
						result.addMulti(expression, "._index");
					}
				}
			}
		}
		return result.toString();
	}

	function toIndentedScope(e: TypedExpr): StringBuf {
		final result = new StringBuf();
		pushNameScope();
		switch(e.expr) {
			case TBlock(el): {
				var empty = true;
				for(i in 0...el.length) {
					final code = excCompileStatement(el[i]);
					if(code != null) {
						if(!empty) {
							result.add("\n");
						}
						empty = false;
						result.add(code.tab());
					}
				}
				if(empty) {
					result.add("\tpass");
				}
			}
			case _: {
				final gdscript = excCompileStatement(e) ?? "pass";
				result.add(gdscript.tab());
			}
		}
		popNameScope();
		return result;
	}

	/**
		Lowers a `try`/`catch` to GDScript. The try body runs inside a
		single-iteration `while true:` so pending-exception checks and
		control-flow statements can unwind with `break`; a dispatch block
		after the loop handles catches and re-emits control flow.
	**/
	function compileTryToGDScript(e: TypedExpr, catches: Array<{ v: TVar, expr: TypedExpr }>): String {
		excUsed = true;
		final id = excTryCounter++;
		final ctrl = "_hx_ctrl" + id;
		final ret = "_hx_ret" + id;
		final eName = "_hx_e" + id;
		final result = new StringBuf();

		result.add("var " + ctrl + ": int = 0\n");
		result.add("var " + ret + " = null\n");
		result.add("while true:\n");
		excTryStack.push({ ctrl: ctrl, ret: ret, loopDepth: 0 });
		result.add(toIndentedScope(e).toString());
		excTryStack.pop();
		result.add("\n\tbreak\n");

		// Catch dispatch. Compiled outside the try context: a throw inside a
		// catch body propagates outward, per Haxe semantics.
		result.add("if " + excClassName + ".active:\n");
		final dispatch = new StringBuf();
		dispatch.add("var " + eName + " = " + excClassName + ".val\n");
		var first = true;
		var hasCatchAll = false;
		for(c in catches) {
			final cond = excCatchCondition(c.v.t, eName);
			if(cond == null) {
				hasCatchAll = true;
				dispatch.add(first ? "if true:\n" : "else:\n");
			} else {
				dispatch.add((first ? "if " : "elif ") + cond + ":\n");
			}
			first = false;

			dispatch.add("\t" + excClassName + ".active = false\n");
			dispatch.add("\t" + excClassName + ".val = null\n");
			dispatch.add("\tvar " + declareLocal(c.v.id, compileVarName(c.v.name)) + " = " + eName + "\n");
			dispatch.add(toIndentedScope(c.expr).toString());
			dispatch.add("\n");
			if(hasCatchAll) break;
		}
		if(!hasCatchAll) {
			// No catch matched: keep the exception pending and unwind further.
			dispatch.add("if " + excClassName + ".active:\n");
			dispatch.add(indentLines(excUnwindLine(), 1));
			dispatch.add("\n");
		}
		result.add(indentLines(dispatch.toString(), 1));
		result.add("\n");

		// Re-emit control flow that unwound out of the try body. Break and
		// continue can only occur when the try sits inside a real loop or an
		// outer lowered try (whose wrapper is a loop).
		final isVoidFunc = excFuncStack.length > 0 && excFuncStack[excFuncStack.length - 1] == null;
		if(excFuncLoopDepth > 0 || excTryStack.length > 0) {
			result.add("if " + ctrl + " == 1:\n");
			result.add(indentLines(excEmitBreak(), 1));
			result.add("\nelif " + ctrl + " == 2:\n");
			result.add(indentLines(excEmitContinue(), 1));
			result.add("\nelif " + ctrl + " == 3:\n");
			result.add(indentLines(excEmitReturn(isVoidFunc ? null : ret), 1));
		} else {
			result.add("if " + ctrl + " == 3:\n");
			result.add(indentLines(excEmitReturn(isVoidFunc ? null : ret), 1));
		}

		return result.toString();
	}

	/**
		Set while compiling arguments substituted into native code injections
		(@:nativeFunctionCode, __gdscript__). In those positions type
		references must compile to their raw GDScript names (e.g. for
		`x is String`), whereas in value positions builtins compile to a
		StringName sentinel since they are not first-class values.
	**/
	var compilingNativeInjectionArgs: Bool = false;

	static final builtinValueTypeNames = [
		"String", "Array", "Dictionary", "int", "float", "bool",
		"StringName", "NodePath", "Callable", "Signal", "PackedByteArray",
		"PackedInt32Array", "PackedInt64Array", "PackedFloat32Array",
		"PackedFloat64Array", "PackedStringArray", "Vector2", "Vector2i",
		"Vector3", "Vector3i", "Vector4", "Vector4i", "Color", "Rect2",
		"Transform2D", "Transform3D", "Basis", "Quaternion", "Plane", "AABB",
		"RID"
	];

	/**
		Compiles a type used as a VALUE (TTypeExpr). Script-backed classes
		compile to their global class name; builtin value types compile to a
		comparable StringName sentinel except inside native code injections.
	**/
	function compileTypeExprValue(m: ModuleType, pos: Position): String {
		switch(m) {
			case TClassDecl(clsRef): {
				final cls = clsRef.get();
				if(cls.isInterface) {
					// Interfaces have no runtime Script; represented by a
					// sentinel resolved through the HxType registry.
					final dotted = cls.pack.length > 0 ? cls.pack.join(".") + "." + cls.name : cls.name;
					return "&\"hxiface:" + dotted + "\"";
				}
				final name = typeCompiler.compileClassName(cls);
				if(cls.isExtern && builtinValueTypeNames.contains(name)) {
					return compilingNativeInjectionArgs ? name : "&\"hx:" + name + "\"";
				}
				return name;
			}
			case TEnumDecl(enmRef): {
				// Enum types have no runtime Script (values are Dictionaries
				// tagged with _hx_enum); represented by a sentinel.
				final e = enmRef.get();
				if(!e.isReflaxeExtern()) {
					return "&\"hxenum:" + EnumCompiler.enumDottedName(e) + "\"";
				}
				return typeCompiler.compileType(TypeHelper.fromModuleType(m), pos) ?? "Variant";
			}
			case TAbstract(absRef): {
				// Primitive abstracts as values get the same sentinel
				// treatment as builtin classes.
				final abs = absRef.get();
				if(abs.pack.length == 0) {
					switch(abs.name) {
						case "Int": return compilingNativeInjectionArgs ? "int" : "&\"hx:int\"";
						case "Float": return compilingNativeInjectionArgs ? "float" : "&\"hx:float\"";
						case "Bool": return compilingNativeInjectionArgs ? "bool" : "&\"hx:bool\"";
						case _:
					}
				}
				return typeCompiler.compileType(TypeHelper.fromModuleType(m), pos) ?? "Variant";
			}
			case _: {
				return typeCompiler.compileType(TypeHelper.fromModuleType(m), pos) ?? "Variant";
			}
		}
	}

	/**
		Returns `true` if the last non-empty line of the compiled body is an
		unconditional `return` at the given indentation depth (i.e. at the
		function's root scope), meaning no trailing return is needed.
	**/
	function endsWithRootReturn(compiledBody: String, depth: Int): Bool {
		final lines = compiledBody.split("\n");
		var i = lines.length - 1;
		while(i >= 0) {
			final line = lines[i];
			if(StringTools.trim(line).length > 0) {
				var prefix = "";
				for(_ in 0...depth) prefix += "\t";
				final expected = prefix + "return";
				if(StringTools.startsWith(line, expected)) {
					final rest = line.substr(expected.length);
					return rest.length == 0 || rest.charAt(0) == " ";
				}
				return false;
			}
			i--;
		}
		return false;
	}

	/**
		Indents every line of `code` by `tabs` tab characters.
	**/
	function indentLines(code: String, tabs: Int): String {
		var prefix = "";
		for(_ in 0...tabs) prefix += "\t";
		return code.split("\n").map(l -> l.length > 0 ? prefix + l : l).join("\n");
	}

	/**
		GDScript condition testing whether the pending exception value matches
		a catch clause type. Returns `null` for catch-all clauses.
	**/
	function excCatchCondition(t: Type, valueName: String): Null<String> {
		return switch(t) {
			case TDynamic(_): null;
			case TAbstract(aRef, params): {
				final a = aRef.get();
				switch(a.name) {
					case "Any": null;
					case "Int": valueName + " is int";
					case "Float": valueName + " is float";
					case "Bool": valueName + " is bool";
					case _: {
						// Follow the abstract to its underlying type.
						final followed = haxe.macro.TypeTools.followWithAbstracts(t);
						switch(followed) {
							case TAbstract(aRef2, _) if(aRef2.get().name == a.name): null;
							case _: excCatchCondition(followed, valueName);
						}
					}
				}
			}
			case TInst(cRef, _): {
				final cls = cRef.get();
				if(cls.name == "String" && cls.pack.length == 0) {
					valueName + " is String";
				} else if(cls.name == "Exception" && cls.pack.length == 1 && cls.pack[0] == "haxe") {
					// haxe.Exception catches everything in Haxe semantics.
					null;
				} else {
					valueName + " is " + typeCompiler.compileClassName(cls);
				}
			}
			case TType(_, _) | TLazy(_) | TMono(_): {
				final followed = haxe.macro.TypeTools.follow(t);
				switch(followed) {
					case TType(_, _): null;
					case _: excCatchCondition(followed, valueName);
				}
			}
			case _: null;
		}
	}

	function constantToGDScript(constant: TConstant): String {
		switch(constant) {
			case TInt(i): return Std.string(i);
			case TFloat(s): return s.indexOf(".") == -1 ? '$s.0' : s;
			case TString(s): return stringToGDScript(s);
			case TBool(b): return b ? "true" : "false";
			case TNull: return "null";
			case TThis: {
				if(selfStack.length > 0) {
					return selfStack[selfStack.length - 1].selfName;
				}
				return "self";
			}
			case TSuper: return "super";
			case _: {}
		}
		return "";
	}

	function stringToGDScript(s: String): String {
		var result = StringTools.replace(s, "\\", "\\\\");
		result = StringTools.replace(result, "\"", "\\\"");
		result = StringTools.replace(result, "\t", "\\t");
		result = StringTools.replace(result, "\n", "\\n");
		result = StringTools.replace(result, "\r", "\\r");
		return "\"" + result + "\"";
	}

	function binopToGDScript(op: Binop, e1: TypedExpr, e2: TypedExpr): String {
		var gdExpr1 = compileExpression(e1);
		var gdExpr2 = compileExpression(e2);

		// Operator precedence differs between Haxe and GDScript (comparisons
		// are one flat left-associative level in GDScript, so
		// `a < 0 != b < 0` parses as `((a < 0) != b) < 0`). Parenthesize
		// operands that are themselves binary operations; redundant parens
		// are harmless.
		inline function isBareBinop(e: TypedExpr): Bool {
			return switch(e.expr) {
				case TBinop(OpAssign | OpAssignOp(_), _, _): false;
				case TBinop(_, _, _): true;
				case _: false;
			}
		}
		final assigning = switch(op) {
			case OpAssign | OpAssignOp(_): true;
			case _: false;
		}
		if(!assigning && isBareBinop(e1) && gdExpr1 != null) gdExpr1 = "(" + gdExpr1 + ")";
		if(isBareBinop(e2) && gdExpr2 != null) gdExpr2 = "(" + gdExpr2 + ")";

		switch(op) {
			case OpUShr: {
				return '(($gdExpr1 & -1) >> $gdExpr2) & -1';
			}
			case OpAssignOp(OpUShr): {
				return '$gdExpr1 = ((($gdExpr1 & -1) >> $gdExpr2) & -1)';
			}
			// Assignment to Array.length maps to resize().
			case OpAssign: {
				switch(e1.expr) {
					case TField(obj, FInstance(clsRef, _, cfRef))
						if(clsRef.get().pack.length == 0 && clsRef.get().name == "Array" && cfRef.get().name == "length"): {
						return compileExpressionOrError(obj) + ".resize(" + gdExpr2 + ")";
					}
					// Haxe array writes grow the array out of bounds;
					// GDScript errors.
					case TArray(arr, idx) if(isHaxeArrayType(arr.t)): {
						hxArrUsed = true;
						return "HxArr.set_at(" + compileExpressionOrError(arr) + ", " + compileExpressionOrError(idx) + ", " + gdExpr2 + ")";
					}
					// Dynamic field writes: reads compile to a helper call,
					// which is not a valid assignment target.
					case TField(obj, FDynamic(fieldName)): {
						hxDynUsed = true;
						return "HxDyn.set_field(" + compileExpressionOrError(obj) + ", \"" + compileVarName(fieldName) + "\", " + gdExpr2 + ")";
					}
					case _:
				}
			}
			// GDScript's % is integer-only; float modulo needs fmod.
			case OpMod if(isFloatModOperand(e1) || isFloatModOperand(e2)): {
				return 'fmod($gdExpr1, $gdExpr2)';
			}
			// Compound assignment to anonymous object fields: those read via
			// .get(), which is not a valid assignment target.
			case OpAssignOp(innerOp): {
				switch(e1.expr) {
					case TField(obj, FAnon(_.get().name => name) | FDynamic(compileVarName(_) => name)): {
						hxDynUsed = true;
						final objCode = compileExpressionOrError(obj);
						final opStr = OperatorHelper.binopToString(innerOp);
						return "HxDyn.set_field(" + objCode + ", \"" + name + "\", HxDyn.get_field(" + objCode + ", \"" + name + "\") " + opStr + " " + gdExpr2 + ")";
					}
					case TArray(arr, idx) if(isHaxeArrayType(arr.t)): {
						hxArrUsed = true;
						final arrCode = compileExpressionOrError(arr);
						final idxCode = compileExpressionOrError(idx);
						final opStr = OperatorHelper.binopToString(innerOp);
						return "HxArr.set_at(" + arrCode + ", " + idxCode + ", HxArr.get_at(" + arrCode + ", " + idxCode + ") " + opStr + " " + gdExpr2 + ")";
					}
					case _: {
						if(innerOp == OpMod && (isFloatModOperand(e1) || isFloatModOperand(e2))) {
							return '$gdExpr1 = fmod($gdExpr1, $gdExpr2)';
						}
					}
				}
			}
			case _:
		}

		final operatorStr = OperatorHelper.binopToString(op);

		// Wrap primitives with Haxe-style string conversion when added
		// with String (floats must not print a trailing .0).
		if(op.isAddition()) {
			if(checkForPrimitiveStringAddition(e1, e2)) gdExpr2 = "HxDyn.hx_string(" + gdExpr2 + ")";
			if(checkForPrimitiveStringAddition(e2, e1)) gdExpr1 = "HxDyn.hx_string(" + gdExpr1 + ")";
		}

		return gdExpr1 + " " + operatorStr + " " + gdExpr2;
	}

	inline function checkForPrimitiveStringAddition(strExpr: TypedExpr, primExpr: TypedExpr) {
		return strExpr.t.isString() && primExpr.t.isPrimitive();
	}

	function isFloatModOperand(e: TypedExpr): Bool {
		return switch(haxe.macro.TypeTools.followWithAbstracts(e.t)) {
			case TAbstract(aRef, _): aRef.get().name == "Float" || aRef.get().name == "Single";
			case _: false;
		}
	}

	/**
		Set when generated code uses the HxArr bounds-safe array helper.
	**/
	var hxArrUsed: Bool = false;

	/**
		TVar ids of local function variables that must be array-wrapped for
		reference-semantics capture (self/mutually recursive lambdas).
		Filled by the WrapRecursiveLambdas preprocessor; keyed by id because
		TVar instances may be copies that do not share metadata.
	**/
	public final recursiveLambdaWrapIds: Map<Int, Bool> = [];

	inline function isArrayWrapped(tvar: TVar): Bool {
		return tvar.meta.maybeHas(":arrayWrap") || recursiveLambdaWrapIds.exists(tvar.id);
	}

	/**
		Set when generated code uses the HxDyn dynamic field access helper.
	**/
	var hxDynUsed: Bool = false;

	/**
		The GDScript source of the dynamic field access helper. Values typed
		as anonymous structures in Haxe may at runtime be Dictionaries,
		Arrays or Strings (length), or class instances.
	**/
	function hxDynRuntimeSource(): String {
		return "class_name HxDyn\n\n"
			+ "# Dynamic field access matching Haxe semantics.\n\n"
			+ "static func get_field(o, name: String):\n"
			+ "\tmatch typeof(o):\n"
			+ "\t\tTYPE_DICTIONARY:\n"
			+ "\t\t\treturn o.get(name)\n"
			+ "\t\tTYPE_ARRAY:\n"
			+ "\t\t\treturn o.size() if name == \"length\" else null\n"
			+ "\t\tTYPE_STRING, TYPE_STRING_NAME:\n"
			+ "\t\t\treturn o.length() if name == \"length\" else null\n"
			+ "\t\tTYPE_OBJECT:\n"
			+ "\t\t\tif o == null:\n"
			+ "\t\t\t\treturn null\n"
			+ "\t\t\tvar v = o.get(name)\n"
			+ "\t\t\tif v == null and o.has_method(name):\n"
			+ "\t\t\t\treturn Callable(o, name)\n"
			+ "\t\t\treturn v\n"
			+ "\t\t_:\n"
			+ "\t\t\treturn null\n\n\n"
			+ "static func set_field(o, name: String, v):\n"
			+ "\tmatch typeof(o):\n"
			+ "\t\tTYPE_DICTIONARY:\n"
			+ "\t\t\to.set(name, v)\n"
			+ "\t\tTYPE_OBJECT:\n"
			+ "\t\t\tif o != null:\n"
			+ "\t\t\t\to.set(name, v)\n"
			+ "\t\t_:\n"
			+ "\t\t\tpass\n"
			+ "\treturn v\n\n\n"
			+ "# Haxe-style string conversion: integral floats print without a\n"
			+ "# trailing .0 (like the js target), enums print Name(params).\n"
			+ "static func hx_string(v) -> String:\n"
			+ "\tmatch typeof(v):\n"
			+ "\t\tTYPE_NIL:\n"
			+ "\t\t\treturn \"null\"\n"
			+ "\t\tTYPE_FLOAT:\n"
			+ "\t\t\tif v == floor(v) and absf(v) < 1e15 and is_finite(v):\n"
			+ "\t\t\t\treturn str(int(v))\n"
			+ "\t\t\treturn str(v)\n"
			+ "\t\tTYPE_DICTIONARY:\n"
			+ "\t\t\tif v.has(\"_hx_enum\"):\n"
			+ "\t\t\t\tvar name: String = v.get(\"_hx_name\", \"\")\n"
			+ "\t\t\t\tvar params := PackedStringArray()\n"
			+ "\t\t\t\tfor k in v.keys():\n"
			+ "\t\t\t\t\tif not (k as String).begins_with(\"_\"):\n"
			+ "\t\t\t\t\t\tparams.append(hx_string(v[k]))\n"
			+ "\t\t\t\treturn name if params.is_empty() else name + \"(\" + \",\".join(params) + \")\"\n"
			+ "\t\t\treturn str(v)\n"
			+ "\t\t_:\n"
			+ "\t\t\treturn str(v)\n";
	}

	function isHaxeArrayType(t: Type): Bool {
		return switch(haxe.macro.TypeTools.follow(t)) {
			case TInst(_.get() => cls, _): cls.pack.length == 0 && cls.name == "Array";
			case _: false;
		}
	}

	/**
		The GDScript source of the bounds-safe array access helper. Haxe
		array reads return null out of bounds and writes grow the array;
		GDScript subscripts error in both cases.
	**/
	function hxArrRuntimeSource(): String {
		return "class_name HxArr\n\n"
			+ "# Bounds-safe array access matching Haxe semantics.\n\n"
			+ "static func get_at(a, i):\n"
			+ "\treturn a[i] if i >= 0 and i < a.size() else null\n\n\n"
			+ "static func set_at(a, i, v):\n"
			+ "\tif i >= a.size():\n"
			+ "\t\ta.resize(i + 1)\n"
			+ "\ta[i] = v\n"
			+ "\treturn v\n";
	}

	function callToGDScript(calledExpr: TypedExpr, arguments: Array<TypedExpr>, originalExpr: TypedExpr): StringBuf {
		// Check @:nativeTypeCode
		var nfcTypes = null;
		final originalExprType = originalExpr.t;
		final wasCompilingInjectionArgs = compilingNativeInjectionArgs;
		compilingNativeInjectionArgs = true;
		final nfc = this.compileNativeFunctionCodeMeta(calledExpr, arguments, function(index: Int) {
			if(nfcTypes == null) nfcTypes = calledExpr.getFunctionTypeParams(originalExprType);
			if(nfcTypes != null && index >= 0 && index < nfcTypes.length) {
				return typeCompiler.compileType(nfcTypes[index], calledExpr.pos);
			}
			return null;
		});
		compilingNativeInjectionArgs = wasCompilingInjectionArgs;

		if(nfc != null) {
			final result = new StringBuf();
			result.add(nfc);
			return result;
		}

		// Check FieldAccess 
		final code = switch(calledExpr.expr) {
			case TField(_, fa): {
				switch(fa) {
					// enum field access
					case FEnum(_, _): {
						compileEnumFieldCall(calledExpr, arguments);
					}
					// @:constructor static function
					case FStatic(classTypeRef, _.get() => cf) if(cf.meta.maybeHas(":constructor")): {
						newToGDScript(classTypeRef, originalExpr, arguments);
					}
					// Replace pad nulls with default values
					case FInstance(clsRef, _, cfRef) | FStatic(clsRef, cfRef): {
						switch(cfRef.get().kind) {
							case FMethod(_): {
								final funcData = cfRef.get().findFuncData(clsRef.get());
								if(funcData != null) {
									arguments = funcData.replacePadNullsWithDefaults(arguments, ":noNullPad", generateInjectionExpression);
								}
							}
							case _:
						}
						null;
					}
					case _: null;
				}
			}
			case _: null;
		}

		final result = new StringBuf();
		if(code != null) {
			result.add(code);
		} else {
			// Dynamic field CALLS dispatch directly (native methods reached
			// through untyped access); reads compile through HxDyn instead.
			switch(calledExpr.unwrapParenthesis().expr) {
				case TField(obj, FDynamic(fieldName)): {
					result.add(compileExpressionOrError(obj));
					result.add(".");
					result.add(compileVarName(fieldName));
					result.add("(");
					result.add(arguments.map(e -> compileCallArg(e)).join(", "));
					result.add(")");
					return result;
				}
				case _:
			}

			final callOp = if(isCallableVar(calledExpr)) {
				".call(";
			} else {
				"(";
			}
			result.add(compileExpression(calledExpr));
			result.add(callOp);
			result.add(arguments.map(e -> compileCallArg(e)).join(", "));
			result.add(")");
		}

		return result;
	}

	/**
		Unique id source for hoisted lambda temporaries.
	**/
	var lambdaHoistCounter: Int = 0;

	/**
		GDScript forbids a local variable from shadowing a parameter or a
		variable of an enclosing scope, and forbids redeclaring a name in the
		same scope (all legal in Haxe). Track declared names per scope and
		rename colliding locals; TLocal references resolve through the rename
		map by TVar id.
	**/
	var scopeNameStack: Array<Array<String>> = [];
	var localRenames: Map<Int, String> = [];

	function pushNameScope() {
		scopeNameStack.push([]);
	}

	function popNameScope() {
		scopeNameStack.pop();
	}

	function declareNameInScope(name: String) {
		if(scopeNameStack.length > 0) {
			scopeNameStack[scopeNameStack.length - 1].push(name);
		}
	}

	function isNameVisible(name: String): Bool {
		for(scope in scopeNameStack) {
			if(scope.contains(name)) return true;
		}
		return false;
	}

	/**
		Returns the (possibly renamed) name for a local declaration and
		registers it in the current scope.
	**/
	function declareLocal(tvarId: Int, baseName: String): String {
		var name = baseName;
		var i = 2;
		while(isNameVisible(name)) {
			name = baseName + i;
			i++;
		}
		if(name != baseName) {
			localRenames.set(tvarId, name);
		}
		declareNameInScope(name);
		return name;
	}

	/**
		Enforces GDScript's rule that optional parameters cannot be followed
		by mandatory ones. Haxe call sites always pass trailing arguments
		explicitly, so the added defaults never fire.
	**/
	function enforceArgumentOrder(compiledArgs: Array<String>): Array<String> {
		var seenOptional = false;
		return compiledArgs.map(arg -> {
			if(arg.indexOf(" = ") >= 0) {
				seenOptional = true;
				return arg;
			}
			if(!seenOptional) return arg;
			final typeIdx = arg.indexOf(": ");
			final def = if(typeIdx < 0) "null" else switch(arg.substr(typeIdx + 2)) {
				case "int": "0";
				case "float": "0.0";
				case "bool": "false";
				case "String": "\"\"";
				case "StringName": "&\"\"";
				case "Dictionary": "{}";
				case t if(StringTools.startsWith(t, "Array")): "[]";
				case _: "null";
			}
			return arg + " = " + def;
		});
	}

	/**
		Compiles a call argument. Multiline lambdas written inline in call
		arguments break GDScript's parser for several constructs (a `match`
		as the lambda's last statement, for instance), so they are hoisted
		into a temporary variable before the call when possible.
	**/
	function compileCallArg(e: TypedExpr): String {
		final compiled = compileExpressionOrError(e);
		switch(e.unwrapParenthesis().expr) {
			case TFunction(_) if(compiled.indexOf("\n") >= 0): {
				final name = "_hx_f" + (lambdaHoistCounter++);
				if(injectExpressionPrefixContent("var " + name + " = " + compiled)) {
					return name;
				}
			}
			case _:
		}
		return compiled;
	}

	function newToGDScript(classTypeRef: Ref<ClassType>, originalExpr: TypedExpr, el: Array<TypedExpr>): String {
		final nfc = this.compileNativeFunctionCodeMeta(originalExpr, el);
		return if(nfc != null) {
			nfc;
		} else {
			final meta = originalExpr.getDeclarationMeta()?.meta;
			final native = meta == null ? "" : ({ name: "", meta: meta }.getNameOrNative());
			final args = el.map(e -> compileExpression(e)).join(", ");
			if(native.length > 0) {
				native + "(" + args + ")";
			} else {
				final cls = classTypeRef.get();
				final className = typeCompiler.compileClassName(cls);
				final meta = cls.meta.maybeExtract(":bindings_api_type");

				// Check for @:bindings_api_type("builtin_classes") metadata
				final builtin_class = meta.filter(m -> switch(m.params) {
					case [macro "builtin_classes"]: true;
					case _: false;
				}).length > 0;

				if(builtin_class) {
					className + "(" + args + ")";
				} else {
					className + ".new(" + args + ")";
				}
			}
		}
	}

	function unopToGDScript(op: Unop, e: TypedExpr, isPostfix: Bool): String {
		final gdExpr = compileExpressionOrError(e);

		// OpIncrement and OpDecrement not supported in GDScript
		switch(op) {
			case OpIncrement | OpDecrement: {
				final opStr = op == OpIncrement ? "+" : "-";
				// Anonymous object fields read via a helper, which is not a
				// valid assignment target; write back through the helper.
				switch(e.unwrapParenthesis().expr) {
					case TField(obj, FAnon(cfRef)): {
						hxDynUsed = true;
						final objCode = compileExpressionOrError(obj);
						final name = cfRef.get().name;
						return "HxDyn.set_field(" + objCode + ", \"" + name + "\", HxDyn.get_field(" + objCode + ", \"" + name + "\") " + opStr + " 1)";
					}
					case _:
				}
				return gdExpr + " " + opStr + "= 1";
			}
			case _:
		}

		final operatorStr = OperatorHelper.unopToString(op);
		return isPostfix ? (gdExpr + operatorStr) : (operatorStr + gdExpr);
	}

	function fieldAccessToGDScript(e: TypedExpr, fa: FieldAccess): String {
		final nameMeta: NameAndMeta = switch(fa) {
			case FInstance(_, _, classFieldRef): classFieldRef.get();
			case FStatic(_, classFieldRef): classFieldRef.get();
			case FAnon(classFieldRef): classFieldRef.get();
			case FClosure(_, classFieldRef): classFieldRef.get();
			case FEnum(_, enumField): enumField;
			case FDynamic(s): { name: s, meta: null };
		}

		if(nameMeta.hasMeta(Meta.Uncompilable)) {
			Context.error("Attempting to compile field marked with `@:uncompilable`.", e.pos);
		}

		return if(nameMeta.hasMeta(":native")) {
			nameMeta.getNameOrNative();
		} else {
			final name = nameMeta.getNameOrNativeName();
			final name = nameMeta.hasMeta(Meta.KeepName) || nameMeta.hasMeta(Meta.NativeName) ? name : compileVarName(name);

			var accessMode: AccessMode = Default;

			switch(fa) {
				// Check if this is a self.field with BypassWrapper OR a field in `bypassSelfStack`
				case FInstance(clsRef, _, clsFieldRef) if(selfStack.length > 0 || bypassSelfStack.length > 0): {
					final isSelfAccess = switch(e.expr) {
						case TConst(TThis): true;
						case _: false;
					}
					if(isSelfAccess) {
						// Check selfStack
						if(selfStack.length > 0) {
							final isSameClass = switch(e.t) {
								case TInst(clsRef2, _) if(clsRef.get().name == clsRef2.get().name): true;
								case _: false;
							}
							if(isSameClass) {
								final selfData = selfStack[selfStack.length - 1];
								final field = clsFieldRef.get();
								if(field.hasMeta(Meta.BypassWrapper) || (selfData.publicOnly && !field.isPublic)) {
									accessMode = ForceSelf;
								}
							}
						}

						// Check bypassSelfStack
						if(accessMode == Default && bypassSelfStack.length > 0) {
							final fieldHaxeName = clsFieldRef.get().name;
							for(name in bypassSelfStack) {
								if(fieldHaxeName == name) {
									accessMode = RemoveFieldAccess;
									break;
								}
							}
						}
					}
				}

				// Check if this is a static variable, and if so use singleton.
				case FStatic(clsRef, cfRef): {
					final cls = clsRef.get();
					final cf = cfRef.get();
					final className = typeCompiler.compileClassName(cls);
					switch(cf.kind) {
						case FMethod(kind): {
							if(kind == MethDynamic) {
								return className + "." + name;
							}
						}
						case _: {
							// If accessing a private static var from itself, don't include the class.
							final currentModule = getCurrentModule();
							switch(currentModule) {
								case TClassDecl(clsRef) if(clsRef.get().equals(cls)): {
									return name;
								}
								case _:
							}
						}
					}
				}

				// Check if this is an enum 
				// TODO... is this correct??? I wrote this in 2022 but idk how this works??
				// [May 2025] Update from 2025, I'm not sure why my past self was hesitant this could be wrong??? Looks good to me?
				case FEnum(enumRef, enumField): {
					return enumCompiler.compileExpressionFromIndex(enumRef.get(), enumField, null);
				}
				case _:
			}

			// Do not use `self.` on `@:const` variables.
			switch(fa) {
				case FInstance(clsRef, _, clsFieldRef): {
					final isSelfAccess = switch(e.expr) {
						case TConst(TThis): true;
						case _: false;
					}
					if(isSelfAccess && clsFieldRef.get().hasMeta(Meta.Const)) {
						return name;
					}
				}
				case FStatic(clsRef, clsFieldRef): {
					final isSelfAccess = switch(e.expr) {
						case TTypeExpr(_ == getCurrentModule() => true): true;
						case _: false;
					}
					if(isSelfAccess && clsFieldRef.get().hasMeta(Meta.Const)) {
						return name;
					}
				}
				case _:
			}

			// Compile "accessed" expression
			final gdExpr = switch(accessMode) {
				case Default: compileExpression(e);
				case ForceSelf: "self";
				case RemoveFieldAccess: return name;
			}

			// Anonymous/dynamic field reads go through a runtime helper:
			// the value may be a Dictionary (anon object, where a missing
			// key must read as null), an Array or String (length), or a
			// class instance (property or method).
			switch(fa) {
				case FAnon(classFieldRef): {
					hxDynUsed = true;
					return "HxDyn.get_field(" + gdExpr + ", \"" + classFieldRef.get().name + "\")";
				}
				case FDynamic(fieldName): {
					hxDynUsed = true;
					return "HxDyn.get_field(" + gdExpr + ", \"" + compileVarName(fieldName) + "\")";
				}
				case _:
			}

			return gdExpr + "." + name;
		}
	}

	

	/**
		In GDScript, a Callable is called differently from a function.
		To help decern whether this is a variable containing a Callable,
		or this is a normal function/method, this function is used.
	**/
	function isCallableVar(e: TypedExpr) {
		return switch(e.expr) {
			case TField(_, fa): {
				switch(fa) {
					case FInstance(_, _, clsFieldRef) |
						FStatic(_, clsFieldRef) |
						FClosure(_, clsFieldRef): {
						final clsField = clsFieldRef.get();
						switch(clsField.kind) {
							case FMethod(methKind): {
								methKind == MethDynamic;
							}
							case _: true;
						}
					}
					case _: true;
				}
			}
			case TConst(c): c != TSuper;
			case TParenthesis(e2) | TMeta(_, e2): isCallableVar(e2);
			case _: true;
		}
	}

	/**
		This is called for called expressions.
		If the typed expression is an enum field, transpile as a
		Dictionary with the enum data.
	**/
	function compileEnumFieldCall(e: TypedExpr, el: Array<TypedExpr>): Null<String> {
		return switch(e.expr) {
			case TField(_, fa): {
				switch(fa) {
					case FEnum(_.get() => enumType, enumField): {
						enumCompiler.compileExpressionFromIndex(enumType, enumField, el);
					}
					case _: null;
				}
			}
			case _: null;
		}
	}
}

#end
