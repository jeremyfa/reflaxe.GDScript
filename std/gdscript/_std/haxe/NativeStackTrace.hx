package haxe;

import haxe.CallStack.StackItem;

/**
	GDScript has no accessible native call stack from scripts in release
	builds; stack traces are unsupported and resolve to empty lists.
**/
@:dox(hide)
@:noCompletion
class NativeStackTrace {
	@:ifFeature("haxe.NativeStackTrace.exceptionStack")
	public static inline function saveStack(exception: Any): Void {
	}

	public static function callStack(): Dynamic {
		return [];
	}

	public static function exceptionStack(): Dynamic {
		return [];
	}

	public static function toHaxe(nativeStackTrace: Dynamic, skip: Int = 0): Array<StackItem> {
		return [];
	}
}
