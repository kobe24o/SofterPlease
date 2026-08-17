package com.softerplease.app

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class BundledModelChannel(private val activity: MainActivity) {
    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.softerplease.app/model_assets")
            .setMethodCallHandler { call, result ->
                if (call.method != "installModels") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val rootPath = call.argument<String>("rootPath")
                        ?: throw IllegalArgumentException("Missing rootPath")
                    val root = File(rootPath)
                    val assets = listOf(
                        "flutter_assets/assets/models/sensevoice/model.int8.onnx" to "sensevoice/model.int8.onnx",
                        "flutter_assets/assets/models/sensevoice/tokens.txt" to "sensevoice/tokens.txt",
                        "flutter_assets/assets/models/vad/ten-vad.int8.onnx" to "vad/ten-vad.int8.onnx",
                        "flutter_assets/assets/models/speaker/model.onnx" to "speaker/model.onnx",
                    )
                    for ((assetPath, outputPath) in assets) {
                        val output = File(root, outputPath)
                        if (output.exists() && output.length() > 0L) continue
                        output.parentFile?.mkdirs()
                        activity.assets.open(assetPath).use { input ->
                            output.outputStream().use { outputStream -> input.copyTo(outputStream) }
                        }
                    }
                    result.success(null)
                } catch (error: Exception) {
                    result.error("model_install_failed", error.message, null)
                }
            }
    }
}
