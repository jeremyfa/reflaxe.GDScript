package gdcompiler.subcompilers;

import gdcompiler.config.Meta;
import gdcompiler.subcompilers.EnumCompiler;
import gdcompiler.GDCompiler;

import reflaxe.helpers.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;

using reflaxe.helpers.ArrayHelper;
using reflaxe.helpers.BaseTypeHelper;
using reflaxe.helpers.ModuleTypeHelper;
using reflaxe.helpers.NameMetaHelper;
using reflaxe.helpers.NullableMetaAccessHelper;
using reflaxe.helpers.TypeHelper;

@:access(gdcompiler.GDCompiler)
class TypeCompiler {
	var main: GDCompiler;

	public function new(main: GDCompiler) {
		this.main = main;
	}

	function isGodotClass(classType: ClassType): Bool {
		return switch(classType.meta.extractExpressionsFromFirstMeta(":bindings_api_type")) {
			case [macro "class"]: true;
			case _ if(classType.superClass != null): isGodotClass(classType.superClass.t.get());
			case _: false;
		}
	}

	public function compileClassName(classType: ClassType): String {
		// Externs (Godot bindings and injected natives) keep their name.
		if(classType.isExtern) {
			return classType.getNameOrNativeName();
		}
		// @:native / @:nativeName take the name verbatim.
		if(classType.hasMeta(":native") || classType.hasMeta(Meta.NativeName)) {
			return classType.getNameOrNativeName();
		}
		return emittedName(classType);
	}

	public function compileEnumName(enumType: EnumType): String {
		if(enumType.isExtern) {
			return enumType.getNameOrNativeName();
		}
		if(enumType.hasMeta(":native") || enumType.hasMeta(Meta.NativeName)) {
			return enumType.getNameOrNativeName();
		}
		return emittedName(enumType);
	}

	/**
		Optional global prefix for generated class names, from
		`-D gdscript_class_prefix=...`. Lets multiple generated code bases
		coexist in one Godot project and avoids clashes with user classes.
	**/
	public function classNamePrefix(): String {
		return Context.definedValue("gdscript_class_prefix") ?? "";
	}

	function packPrefixedName(pack: Array<String>, name: String): String {
		return pack.length >= 1 ? pack.join("_") + "_" + name : name;
	}

	// =======================================================
	// * Name registry
	//
	// Global class_name declarations must be unique and should stay short.
	// A table over ALL module types resolves each generated type to its
	// plain name when unambiguous, escalating deterministically on
	// collision: plain name -> package-qualified -> module-qualified.
	// The optional `gdscript_class_prefix` is applied on top, and
	// `-D gdscript_qualified_names` restores always-qualified names.
	// =======================================================

	/**
		All module types of the compilation, provided by
		`GDCompiler.filterTypes` before anything compiles.
	**/
	var allModuleTypes: Null<Array<ModuleType>> = null;

	/**
		Resolved (unprefixed) name per type key; built lazily.
	**/
	var nameTable: Null<Map<String, String>> = null;

	public function setModuleTypes(types: Array<ModuleType>) {
		allModuleTypes = types;
		nameTable = null;
	}

	static function nameTableKey(bt: BaseType): String {
		return bt.module + "|" + bt.name;
	}

	/**
		The emitted global name for a generated (non-extern) type. Falls back
		to the package-qualified form when the type is unknown to the table.
	**/
	public function emittedName(bt: BaseType): String {
		if(nameTable == null) {
			buildNameTable();
		}
		final resolved = nameTable != null ? nameTable.get(nameTableKey(bt)) : null;
		return classNamePrefix() + (resolved ?? packPrefixedName(bt.pack, bt.name));
	}

	function buildNameTable() {
		nameTable = [];
		if(allModuleTypes == null) return;

		final alwaysQualified = #if eval Context.defined("gdscript_qualified_names") #else false #end;

		final entries: Array<BaseType> = [];
		for(m in allModuleTypes) {
			final bt: Null<BaseType> = switch(m) {
				case TClassDecl(c): {
					final cls = c.get();
					(cls.isExtern || cls.hasMeta(":native") || cls.hasMeta(Meta.NativeName)) ? null : (cls : BaseType);
				}
				case TEnumDecl(e): {
					final en = e.get();
					(en.isExtern || en.hasMeta(":native") || en.hasMeta(Meta.NativeName)) ? null : (en : BaseType);
				}
				case _: null;
			}
			if(bt != null) entries.push(bt);
		}

		// Tier 1: plain names where unambiguous (also avoid the runtime
		// helper names emitted by the compiler itself).
		final reserved = ["HxExc", "HxDyn", "HxArr", "HxVarArgs", "HxType", "HxAutoLoad"];
		final byName = new Map<String, Array<BaseType>>();
		for(bt in entries) {
			final list = byName.get(bt.name);
			if(list != null) list.push(bt);
			else byName.set(bt.name, [bt]);
		}

		final tier2: Array<BaseType> = [];
		for(name => list in byName) {
			if(!alwaysQualified && list.length == 1 && !reserved.contains(name)) {
				nameTable.set(nameTableKey(list[0]), name);
			} else {
				for(bt in list) tier2.push(bt);
			}
		}

		// Tier 2: package-qualified; tier 3 (same package, different
		// modules): module-qualified.
		final byQualified = new Map<String, Array<BaseType>>();
		for(bt in tier2) {
			final qualified = packPrefixedName(bt.pack, bt.name);
			final list = byQualified.get(qualified);
			if(list != null) list.push(bt);
			else byQualified.set(qualified, [bt]);
		}
		for(qualified => list in byQualified) {
			if(list.length == 1) {
				nameTable.set(nameTableKey(list[0]), qualified);
			} else {
				for(bt in list) {
					final moduleId = StringTools.replace(bt.module, ".", "_");
					nameTable.set(nameTableKey(bt), moduleId + "_" + bt.name);
				}
			}
		}
	}

	function compileModuleType(m: ModuleType, isExport: Bool): String {
		return switch(m) {
			case TClassDecl(clsRef): {
				compileClassName(clsRef.get());
			}
			case TEnumDecl(enmRef): {
				compileEnum(enmRef, isExport);
			}
			case _: m.getNameOrNative();
		}
	}

	function compileEnum(enmRef: Ref<EnumType>, isExport: Bool) {
		final e = enmRef.get();
		return if(e.isReflaxeExtern()) {
			e.pack.joinAppend(".") + e.getNameOrNativeName();
		} else {
			final kind = main.enumCompiler.getCompileKind(e);
			switch(kind) {
				case GDScriptEnum: {
					final name = compileEnumName(e);
					name + "." + name;
				}
				case AsInt: {
					"int";
				}
				case AsDictionary: {
					if(!isExport) {
						"Variant";
					} else {
						"Dictionary";
					}
				}
			}
		}
	}

	public function compileType(t: Type, errorPos: Position, isExport: Bool = false): Null<String> {
		// Check for @:dont_compile
		if(t.getMeta().maybeHas(Meta.DontCompile)) {
			return null;
		}

		// Haxe String and Array are nullable reference types, but their
		// GDScript counterparts are non-nullable builtins. Code that assigns
		// or returns null through them is valid Haxe, so these compile
		// untyped.
		switch(t) {
			case TInst(_.get() => cls, _) if(cls.pack.length == 0 && (cls.name == "String" || cls.name == "Array")): {
				return null;
			}
			case _:
		}

		// Process and return content from @:nativeTypeCode
		if(t.getMeta().maybeHas(":nativeTypeCode")) {
			final params = t.getParams();
			final paramCallbacks = if(params != null && params.length > 0) {
				// GDScript does not support nested typed collections
				// (e.g. Array[Array[int]]), so parameters that are themselves
				// parameterized degrade to Variant.
				params.map(paramType -> (() -> {
					final compiled = compileType(paramType, errorPos, isExport) ?? "Variant";
					compiled.indexOf("[") >= 0 ? "Variant" : compiled;
				}));
			} else {
				[];
			}
			final code = main.compileNativeTypeCodeMeta(t, paramCallbacks);
			if(code != null) {
				return code;
			}
		}

		if(t.isNull()) {
			// Primitives, Arrays, Dictionaries, and copy-types (Vector2, etc.) cannot be assigned `null`.
			// The only way to handle these is to remain "untyped" at the moment.
			//
			// Object types are generated with `@:bindings_api_type("class")`, so those are safe to
			// type and assign `null`.
			final unwrappedType = Context.followWithAbstracts(t.unwrapNullTypeOrSelf(), true);
			switch(unwrappedType) {
				case TInst(clsRef, _): {
					if(isGodotClass(clsRef.get())) {
						return compileType(unwrappedType, errorPos, isExport);
					}
				}
				case _:
			}

			return null;
		}
		// Ignore Null<T> and just compile as T
		// if(t.isNull()) {
		// 	switch(Context.follow(t.unwrapNullTypeOrSelf())) {
		// 		case TEnum(_, _) | TAnonymous(_) if(!isExport): return "Variant";
		// 		case _:
		// 	}
		// 	return compileType(t.unwrapNullTypeOrSelf(), errorPos, isExport);
		// }

		switch(t) {
			case TAbstract(_, _) if(t.isMultitype()): {
				return compileType(Context.followWithAbstracts(t, true), errorPos, isExport);
			}
			case TAbstract(absRef, params): {
				final abs = absRef.get();

				// Class/Enum/EnumValue have no GDScript representation
				// (classes are Script objects, enums are Dictionaries):
				// leave those untyped.
				if(abs.pack.length == 0) {
					switch(abs.name) {
						case "Class" | "Enum" | "EnumValue": return null;
						case _:
					}
				}

				final primitiveResult = if(params.length == 0) {
					switch(abs.name) {
						case "Void": "void";
						case "Int": "int";
						case "Float":"float";
						case "Single": "float";
						case "Bool": "bool";
						case "Any" | "Dynamic": null;
						case _: null;
					}
				} else {
					null;
				}

				if(primitiveResult != null) {
					return primitiveResult;
				}

				// Compile internal type for Abstract
				final absType = abs.type;

				// Apply type parameters to figure out internal type.
				final internalType = #if macro {
					TypeTools.applyTypeParameters(absType, abs.params, params);
				} #else absType #end;

				// If Null<T>, must be Variant since built-in types cannot be assigned `null`.
				if(internalType.isNull()) {
					return null;
				}

				// Prevent recursion...
				if(!internalType.equals(t)) {
					return compileType(internalType, errorPos, isExport);
				}
			}

			case TDynamic(_): return null;
			case TAnonymous(_): return "Variant";
			case TFun(_, _): return null;
			case _ if(t.isTypeParameter()): return null;

			case TInst(_.get() => cls, _) if(cls.isInterface): {
				// Interfaces don't exist, just use a Variant
				return "Variant";
			}
			case TInst(clsRef, _): {
				return compileModuleType(TClassDecl(clsRef), isExport);
			}
			case TEnum(enmRef, _): return compileEnum(enmRef, isExport);
			case TType(defRef, _): return compileType(defRef.get().type, errorPos, isExport);

			case TMono(typeRef): {
				final t = typeRef.get();
				return if(t != null) compileType(t, errorPos, isExport);
				else null; // It's okay to return `null` here.
			}

			case _:
		}

		// Old behavior
		// TODO: Phase this out...
		final ct = haxe.macro.TypeTools.toComplexType(t);
		final typeName = switch(ct) {
			case TPath(typePath): {
				// copy TypePath and ignore "params" since GDScript is typeless
				haxe.macro.ComplexTypeTools.toString(TPath({
					name: typePath.name,
					pack: typePath.pack,
					sub: typePath.sub,
					params: null
				}));
			}
			case _: null;
		}
		if(typeName == null) {
			return Context.error("Incomplete Feature: Cannot convert this type to GDScript at the moment. " + Std.string(t), errorPos);
		}
		return typeName;
	}
}
