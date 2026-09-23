import Flutter
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TiptoeWifi") else {
      return
    }
    let channel = FlutterMethodChannel(name: "com.tiptoe/wifi", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "join":
        let ssid = args?["ssid"] as? String ?? ""
        let pass = args?["pass"] as? String ?? ""
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: pass, isWEP: false)
        config.joinOnce = true
        NEHotspotConfigurationManager.shared.apply(config) { error in
          if let error = error as NSError?,
             error.domain == NEHotspotConfigurationErrorDomain,
             error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            result(true)
            return
          }
          result(error == nil)
        }
      case "leave":
        if let ssid = args?["ssid"] as? String, !ssid.isEmpty {
          NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        }
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
