package com.onebill.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.ContactsContract
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val CONTACT_CHANNEL = "com.onebill.app/contact_picker"
    private val REQUEST_CODE_PICK_CONTACT = 2026
    private var pendingContactResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONTACT_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "pickContact") {
                    if (pendingContactResult != null) {
                        result.error("ALREADY_ACTIVE", "A contact picker is already active", null)
                        return@setMethodCallHandler
                    }
                    pendingContactResult = result
                    try {
                        val intent = Intent(Intent.ACTION_PICK).apply {
                            type = ContactsContract.CommonDataKinds.Phone.CONTENT_TYPE
                        }
                        startActivityForResult(intent, REQUEST_CODE_PICK_CONTACT)
                    } catch (e: Exception) {
                        pendingContactResult = null
                        result.error("UNAVAILABLE", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_PICK_CONTACT) {
            val result = pendingContactResult ?: return
            pendingContactResult = null

            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val contactUri: Uri = data.data!!
                val projection = arrayOf(
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER
                )

                try {
                    contentResolver.query(contactUri, projection, null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val nameIdx = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                            val numberIdx = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)

                            val name = if (nameIdx != -1) cursor.getString(nameIdx) else ""
                            val number = if (numberIdx != -1) cursor.getString(numberIdx) else ""

                            val map = mapOf(
                                "name" to (name ?: ""),
                                "phone" to (number ?: "")
                            )
                            result.success(map)
                            return
                        }
                    }
                    result.success(null)
                } catch (e: Exception) {
                    result.error("QUERY_FAILED", e.message, null)
                }
            } else {
                result.success(null)
            }
        }
    }
}
