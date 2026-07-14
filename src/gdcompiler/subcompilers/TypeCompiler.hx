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
		// Include the package to keep global class_name declarations unique:
		// same-name classes in different packages would otherwise collide, and
		// bare names can shadow Godot built-ins (Timer, Script, ...).
		return classNamePrefix() + packPrefixedName(classType.pack, classType.name);
	}

	public function compileEnumName(enumType: EnumType): String {
		if(enumType.isExtern) {
			return enumType.getNameOrNativeName();
		}
		if(enumType.hasMeta(":native") || enumType.hasMeta(Meta.NativeName)) {
			return enumType.getNameOrNativeName();
		}
		return classNamePrefix() + packPrefixedName(enumType.pack, enumType.name);
	}

	/**
		Optional global prefix for generated class names, from
		`-D gdscript_class_prefix=...`. Lets multiple generated code bases
		coexist in one Godot project and avoids clashes with user classes.
	**/
	function classNamePrefix(): String {
		return Context.definedValue("gdscript_class_prefix") ?? "";
	}

	function packPrefixedName(pack: Array<String>, name: String): String {
		return pack.length >= 1 ? pack.join("_") + "_" + name : name;
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
