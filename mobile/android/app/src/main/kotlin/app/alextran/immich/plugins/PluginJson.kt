package app.alextran.immich.plugins

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener

/** JSON helpers shared by the native plugin runtime. */
internal object PluginJson {
  /** Converts maps, lists, arrays and primitives (method channel values) into org.json values. */
  fun toJson(value: Any?): Any = when (value) {
    null -> JSONObject.NULL
    is JSONObject, is JSONArray, is String, is Boolean, is Int, is Long, is Double -> value
    is Float -> value.toDouble()
    is Number -> value.toLong()
    is Map<*, *> -> JSONObject().also { json -> value.forEach { (key, item) -> json.put(key.toString(), toJson(item)) } }
    is Iterable<*> -> JSONArray().also { json -> value.forEach { json.put(toJson(it)) } }
    is Array<*> -> JSONArray().also { json -> value.forEach { json.put(toJson(it)) } }
    is IntArray -> JSONArray().also { json -> value.forEach { json.put(it) } }
    is LongArray -> JSONArray().also { json -> value.forEach { json.put(it) } }
    is DoubleArray -> JSONArray().also { json -> value.forEach { json.put(it) } }
    is BooleanArray -> JSONArray().also { json -> value.forEach { json.put(it) } }
    else -> value.toString()
  }

  /** Converts org.json values into maps, lists and primitives. */
  fun fromJson(value: Any?): Any? = when (value) {
    null, JSONObject.NULL -> null
    is JSONObject -> buildMap {
      val keys = value.keys()
      while (keys.hasNext()) {
        val key = keys.next()
        put(key, fromJson(value.opt(key)))
      }
    }
    is JSONArray -> List(value.length()) { fromJson(value.opt(it)) }
    else -> value
  }

  /** JSON text of any value. */
  fun stringify(value: Any?): String = when (val json = toJson(value)) {
    is JSONObject, is JSONArray -> json.toString()
    JSONObject.NULL -> "null"
    is String -> JSONObject.quote(json)
    else -> json.toString()
  }

  /** Parses JSON text; null for blank or invalid input. */
  fun parse(text: String?): Any? {
    if (text.isNullOrBlank()) {
      return null
    }
    return try {
      JSONTokener(text).nextValue()
    } catch (_: JSONException) {
      null
    }
  }

  fun obj(text: String?): JSONObject = parse(text) as? JSONObject ?: JSONObject()

  fun array(text: String?): JSONArray = parse(text) as? JSONArray ?: JSONArray()

  /** Returns [text] if it is valid JSON, otherwise [text] as a JSON string; `null` for null. */
  fun normalize(text: String?): String {
    if (text == null) {
      return "null"
    }
    return if (parse(text) != null || text.trim() == "null") text else JSONObject.quote(text)
  }

  fun ok(responseJson: String?): String = "{\"success\":true,\"response\":${normalize(responseJson)}}"

  fun error(status: Int, message: String): String =
    JSONObject().put("success", false).put("status", status).put("message", message).toString()

  fun JSONObject.str(key: String): String? = if (has(key) && !isNull(key)) optString(key) else null

  fun JSONObject.intOrNull(key: String): Int? = if (has(key) && !isNull(key)) optInt(key) else null

  fun JSONObject.longOrNull(key: String): Long? = if (has(key) && !isNull(key)) optLong(key) else null

  fun JSONArray.str(index: Int): String? = if (index < length() && !isNull(index)) optString(index) else null
}
