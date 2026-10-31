package dev.akash.cs3engine.android

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import com.lagradost.cloudstream3.CloudStreamApp
import com.lagradost.cloudstream3.CommonActivity
import dev.akash.cs3engine.Engine
import dev.akash.cs3engine.Json
import dev.akash.cs3engine.android.ui.AndroidUiHost
import dev.akash.cs3engine.android.ui.ExtensionPageFactory
import dev.akash.cs3engine.android.ui.WindowHook
import dev.akash.cs3engine.android.ui.WindowOwners
import dev.akash.cs3engine.host.HostHooks
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Hosts the engine in the app process; Dart talks to it over the `cs3_engine` channel. */
class Cs3EnginePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "cs3_engine")
        channel.setMethodCallHandler(this)
        // Extensions' own pages, lent to the sheet (part 5).
        binding.platformViewRegistry.registerViewFactory(ExtensionPageFactory.VIEW_TYPE, ExtensionPageFactory { ui })
        HostHooks.log = { Log.i(TAG, it) }
        HostHooks.toast = { message ->
            Handler(Looper.getMainLooper()).post { Toast.makeText(appContext, message, Toast.LENGTH_SHORT).show() }
        }
        // Events come from plugin threads; the channel is used on the main thread.
        HostHooks.event = { event -> Handler(Looper.getMainLooper()).post { channel.invokeMethod("event", event) } }
        // An extension asked to restart the app: its code is stopped where it asked, and the app
        // is told, so the extension is loaded again - which is what the restart would have done,
        // and what makes the settings the extension saved apply.
        HostHooks.restartRequested = { error ->
            val plugin = engine?.pluginFileIn(error)?.absolutePath ?: ""
            runCatching {
                Json.mapper.writeValueAsString(
                    mapOf("event" to "restartRequested", "plugin" to plugin)
                )
            }.onSuccess { event -> HostHooks.event(event) }
        }
        // The WebView's own agent, as CloudStream's resolver read it from the WebView it made.
        HostHooks.browserAgent = { browserAgent(appContext) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        HostHooks.event = {}
        HostHooks.browserAgent = { null }
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "call") return result.notImplemented()
        val request = call.argument<String>("request")!!
        scope.launch {
            val response = withContext(Dispatchers.IO) {
                // Engine start-up failures must reach Dart as errors, not crash the app.
                try {
                    engine(appContext).respond(request)
                } catch (t: Throwable) {
                    Json.error(null, t)
                }
            }
            result.success(response)
        }
    }

    // Plugins that build settings UI need the real activity, like in CloudStream.
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        CommonActivity.setActivityInstance(binding.activity)
        val fragments = binding.activity as? androidx.fragment.app.FragmentActivity ?: return
        if (!WindowHook.installed) ui?.watchFragments(fragments)
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = CommonActivity.setActivityInstance(null)
    override fun onDetachedFromActivity() = CommonActivity.setActivityInstance(null)

    companion object {
        private const val TAG = "cs3"

        @Volatile
        private var engine: Engine? = null

        @Volatile
        private var ui: AndroidUiHost? = null

        /** One engine per process: plugins register providers into process-wide state. */
        @Synchronized
        private fun engine(context: Context): Engine = engine ?: run {
            CloudStreamApp.installContext(context)
            if (context.applicationContext !is ExtensionHostApplication) {
                Log.w(TAG, "the app's Application isn't ExtensionHostApplication: an extension restarting through it ends the app")
            }
            val ui = AndroidUiHost(
                WindowOwners(
                    pluginIn = { error -> engine?.pluginFileIn(error) },
                    pluginOf = { type -> engine?.pluginFileOf(type) },
                    activity = { CommonActivity.activity },
                ),
                resourcesOf = { file -> engine?.pluginResources(file) },
            )
            Cs3EnginePlugin.ui = ui
            Engine(AndroidPluginLoader(context), { CommonActivity.activity ?: context }, "android", ui).also { created ->
                engine = created
                PluginCrashGuard.install(created::pluginIn)
                RestartGuard.start(extensionCalling = { created.pluginFileIn(Throwable()) != null })
                WindowHook.install(ui)
                if (!WindowHook.installed) (CommonActivity.activity as? androidx.fragment.app.FragmentActivity)?.let(ui::watchFragments)
            }
        }
    }
}
