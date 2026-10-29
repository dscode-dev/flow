import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var authConfigurationChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FlowAuthConfiguration") else { return }
    let channel = FlutterMethodChannel(
      name: "flow/auth_configuration", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "googleIosReady", let clientID = call.arguments as? String,
        clientID.hasSuffix(".apps.googleusercontent.com") else {
        result(false)
        return
      }
      let expected = clientID.components(separatedBy: ".").reversed().joined(separator: ".")
      let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
      let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
      result(schemes.contains(expected))
    }
    authConfigurationChannel = channel
  }
}
