package;

/**
	Minimal Date implementation backed by unix time (seconds, UTC).
	Provides what the cross-platform std (haxe.format, DateTools) needs.
**/
class Date {
	var seconds: Float;

	public function new(year: Int, month: Int, day: Int, hour: Int, min: Int, sec: Int) {
		final dict: Dynamic = untyped __gdscript__(
			"{ \"year\": {0}, \"month\": {1}, \"day\": {2}, \"hour\": {3}, \"minute\": {4}, \"second\": {5} }",
			year, month + 1, day, hour, min, sec
		);
		seconds = untyped __gdscript__("Time.get_unix_time_from_datetime_dict({0})", dict);
	}

	public function getTime(): Float {
		return seconds * 1000.0;
	}

	public function getFullYear(): Int {
		return untyped __gdscript__("Time.get_datetime_dict_from_unix_time(int({0}))[\"year\"]", seconds);
	}

	public function getMonth(): Int {
		final m: Int = untyped __gdscript__("Time.get_datetime_dict_from_unix_time(int({0}))[\"month\"]", seconds);
		return m - 1;
	}

	public function getDate(): Int {
		return untyped __gdscript__("Time.get_datetime_dict_from_unix_time(int({0}))[\"day\"]", seconds);
	}

	public function getHours(): Int {
		return untyped __gdscript__("Time.get_datetime_dict_from_unix_time(int({0}))[\"hour\"]", seconds);
	}

	public function getMinutes(): Int {
		return untyped __gdscript__("Time.get_datetime_dict_from_unix_time(int({0}))[\"minute\"]", seconds);
	}

	public function getSeconds(): Int {
		return untyped __gdscript__("Time.get_datetime_dict_from_unix_time(int({0}))[\"second\"]", seconds);
	}

	public function getDay(): Int {
		return untyped __gdscript__("Time.get_datetime_dict_from_unix_time(int({0}))[\"weekday\"]", seconds);
	}

	public function toString(): String {
		return untyped __gdscript__("Time.get_datetime_string_from_unix_time(int({0}), true)", seconds);
	}

	public static function now(): Date {
		final d = new Date(1970, 0, 1, 0, 0, 0);
		d.seconds = untyped __gdscript__("Time.get_unix_time_from_system()");
		return d;
	}

	public static function fromTime(t: Float): Date {
		final d = new Date(1970, 0, 1, 0, 0, 0);
		d.seconds = t / 1000.0;
		return d;
	}

	public static function fromString(s: String): Date {
		final d = new Date(1970, 0, 1, 0, 0, 0);
		d.seconds = untyped __gdscript__("Time.get_unix_time_from_datetime_string({0})", s);
		return d;
	}
}
