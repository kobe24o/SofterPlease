package com.softerplease.app

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class AppUpdateChannel(private val activity: MainActivity) {
    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.softerplease.app/update")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "inspectApk" -> result.success(inspectApk(requireApk(call)))
                        "canRequestPackageInstalls" -> result.success(
                            Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls(),
                        )
                        "openInstallPermission" -> {
                            if (Build.VERSION.SDK_INT >= 26) {
                                activity.startActivity(Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:${activity.packageName}"),
                                ))
                            }
                            result.success(null)
                        }
                        "installApk" -> {
                            val file = requireApk(call)
                            if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                                throw IllegalStateException("Installation permission is required")
                            }
                            val updates = File(activity.cacheDir, "updates").canonicalFile
                            if (file.canonicalFile.parentFile != updates) {
                                throw IllegalArgumentException("Update APK is outside the private update cache")
                            }
                            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.update-files", file)
                            activity.startActivity(Intent(Intent.ACTION_INSTALL_PACKAGE)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("update_bridge_error", error.message, null)
                }
            }
    }

    private fun requireApk(call: MethodCall): File {
        val path = call.argument<String>("path") ?: throw IllegalArgumentException("APK path is required")
        return File(path).takeIf { it.isFile && it.name.endsWith(".apk", true) }
            ?: throw IllegalArgumentException("Update APK is unavailable")
    }

    @Suppress("DEPRECATION")
    private fun inspectApk(file: File): Map<String, Any> {
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val info = activity.packageManager.getPackageArchiveInfo(file.path, flags)
            ?: throw IllegalArgumentException("Unable to inspect update APK")
        val certificate = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners?.singleOrNull() else info.signatures?.singleOrNull()
            ?: throw IllegalArgumentException("Update APK has no single signing certificate")
        return mapOf(
            "packageName" to info.packageName,
            "versionCode" to versionCode(info),
            "certificateSha256" to sha256(certificate.toByteArray()),
        )
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
