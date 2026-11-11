package app.alextran.immich.plugins

import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider

/**
 * Shares hidden private files with the app that opened the picker, presenting them under
 * their original name and type (without the `.private` suffix the file has on disk).
 */
class PrivateFileProvider : FileProvider() {
  override fun query(
    uri: Uri,
    projection: Array<out String>?,
    selection: String?,
    selectionArgs: Array<out String>?,
    sortOrder: String?,
  ): Cursor {
    val source = super.query(uri, projection, selection, selectionArgs, sortOrder)
    val columns = source.columnNames
    val result = MatrixCursor(columns, source.count)
    source.use {
      while (it.moveToNext()) {
        result.addRow(
          columns.mapIndexed { index, column ->
            when {
              column == OpenableColumns.DISPLAY_NAME -> it.getString(index)?.let(::originalName)
              it.getType(index) == Cursor.FIELD_TYPE_INTEGER -> it.getLong(index)
              it.isNull(index) -> null
              else -> it.getString(index)
            }
          },
        )
      }
    }
    return result
  }

  override fun getType(uri: Uri): String? {
    val name = uri.lastPathSegment?.let(::originalName) ?: return super.getType(uri)
    val extension = name.substringAfterLast('.', "").lowercase()
    return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: super.getType(uri)
  }

  private fun originalName(name: String): String = name.removeSuffix(SUFFIX)

  private companion object {
    const val SUFFIX = ".private"
  }
}
