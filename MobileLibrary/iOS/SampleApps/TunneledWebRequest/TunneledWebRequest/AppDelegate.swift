//
//  AppDelegate.swift
//  TunneledWebRequest
//
/*
Licensed under Creative Commons Zero (CC0).
https://creativecommons.org/publicdomain/zero/1.0/
*/

import UIKit

import PsiphonTunnel


@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

	// The instance of PsiphonTunnel we'll use for connecting.
	var psiphonTunnel: PsiphonTunnel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.

		self.psiphonTunnel = PsiphonTunnel.newPsiphonTunnel(self)

        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.

		DispatchQueue.global(qos: .default).async {
			// Start up the tunnel and begin connecting.
			// This could be started elsewhere or earlier.
			NSLog("Starting tunnel")

			guard let success = self.psiphonTunnel?.start(true), success else {
				NSLog("psiphonTunnel.start returned false")
				return
			}

			// The Psiphon Library exposes reachability functions, which can be used for detecting internet status.
			let reachability = Reachability.forInternetConnection()
			let networkStatus = reachability?.currentReachabilityStatus()
			NSLog("Internet is reachable? \(networkStatus != NotReachable)")
		}
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.

		// Clean up the tunnel
		NSLog("Stopping tunnel")
		self.psiphonTunnel?.stop()
    }

	/// Request URL using URLSession configured to use the current proxy.
	/// * parameters:
	///   - url: The URL to request.
	///   - completion: A callback function that will received the string obtained
	///     from the request, or nil if there's an error.
	/// * returns: The string obtained from the request, or nil if there's an error.
	func makeRequestViaUrlSessionProxy(_ url: String, completion: @escaping (_ result: String?) -> ()) {
		let socksProxyPort = self.psiphonTunnel!.getLocalSocksProxyPort()
		assert(socksProxyPort > 0)

		let request = URLRequest(url: URL(string: url)!)

		let config = URLSessionConfiguration.ephemeral
		config.requestCachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
		config.connectionProxyDictionary = [AnyHashable: Any]()

		// Enable and set the SOCKS proxy values.
		config.connectionProxyDictionary?[kCFStreamPropertySOCKSProxy as String] = 1
		config.connectionProxyDictionary?[kCFStreamPropertySOCKSProxyHost as String] = "127.0.0.1"
		config.connectionProxyDictionary?[kCFStreamPropertySOCKSProxyPort as String] = socksProxyPort

		// Alternatively, the HTTP proxy can be used. Below are the settings for that.
		// The HTTPS key constants are mismatched and Xcode gives deprecation warnings, but they seem to be necessary to proxy HTTPS requests. This is probably a bug on Apple's side; see: https://forums.developer.apple.com/thread/19356#131446
		// config.connectionProxyDictionary?[kCFNetworkProxiesHTTPEnable as String] = 1
		// config.connectionProxyDictionary?[kCFNetworkProxiesHTTPProxy as String] = "127.0.0.1"
		// config.connectionProxyDictionary?[kCFNetworkProxiesHTTPPort as String] = self.httpProxyPort
		// config.connectionProxyDictionary?[kCFStreamPropertyHTTPSProxyHost as String] = "127.0.0.1"
		// config.connectionProxyDictionary?[kCFStreamPropertyHTTPSProxyPort as String] = self.httpProxyPort

		let session = URLSession.init(configuration: config, delegate: nil, delegateQueue: OperationQueue.current)

		// Create the URLSession task that will make the request via the tunnel proxy.
		let task = session.dataTask(with: request) {
			(data: Data?, response: URLResponse?, error: Error?) in
			if error != nil {
				NSLog("Client-side error in request to \(url): \(String(describing: error))")
				// Invoke the callback indicating error.
				completion(nil)
				return
			}

			if data == nil {
				NSLog("Data from request to \(url) is nil")
				// Invoke the callback indicating error.
				completion(nil)
				return
			}

			let httpResponse = response as? HTTPURLResponse
			if httpResponse?.statusCode != 200 {
				NSLog("Server-side error in request to \(url): \(String(describing: httpResponse))")
				// Invoke the callback indicating error.
				completion(nil)
				return
			}

			let encodingName = response?.textEncodingName != nil ? response?.textEncodingName : "utf-8"
			let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(encodingName as CFString!))

			let stringData = String(data: data!, encoding: String.Encoding(rawValue: UInt(encoding)))

			// Make sure the session is cleaned up.
			session.invalidateAndCancel()

			// Invoke the callback with the result.
			completion(stringData)
		}

		// Start the request task.
		task.resume()
	}

	/// Request URL using Psiphon's "URL proxy" mode.
	/// For details, see the comment near the top of:
	/// https://github.com/Psiphon-Labs/psiphon-tunnel-core/blob/master/psiphon/httpProxy.go
	/// * parameters:
	///   - url: The URL to request.
	///   - completion: A callback function that will received the string obtained
	///     from the request, or nil if there's an error.
	/// * returns: The string obtained from the request, or nil if there's an error.
	func makeRequestViaUrlProxy(_ url: String, completion: @escaping (_ result: String?) -> ()) {
		let httpProxyPort = self.psiphonTunnel!.getLocalHttpProxyPort()
		assert(httpProxyPort > 0)

		// The target URL must be encoded so as to be valid within a query parameter.
		// See this SO answer for why we're using this CharacterSet (and not using: https://stackoverflow.com/a/24888789
		let queryParamCharsAllowed = CharacterSet.init(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

		let encodedTargetURL = url.addingPercentEncoding(withAllowedCharacters: queryParamCharsAllowed)

		let proxiedURL = "http://127.0.0.1:\(httpProxyPort)/tunneled/\(encodedTargetURL!)"

		let task = URLSession.shared.dataTask(with: URL(string: proxiedURL)!) {
			(data: Data?, response: URLResponse?, error: Error?) in
			if error != nil {
				NSLog("Client-side error in request to \(url): \(String(describing: error))")
				// Invoke the callback indicating error.
				completion(nil)
				return
			}

			if data == nil {
				NSLog("Data from request to \(url) is nil")
				// Invoke the callback indicating error.
				completion(nil)
				return
			}

			let httpResponse = response as? HTTPURLResponse
			if httpResponse?.statusCode != 200 {
				NSLog("Server-side error in request to \(url): \(String(describing: httpResponse))")
				// Invoke the callback indicating error.
				completion(nil)
				return
			}

			let encodingName = response?.textEncodingName != nil ? response?.textEncodingName : "utf-8"
			let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding(encodingName as CFString!))

			let stringData = String(data: data!, encoding: String.Encoding(rawValue: UInt(encoding)))

			// Invoke the callback with the result.
			completion(stringData)
		}

		// Start the request task.
		task.resume()
	}
}


// MARK: TunneledAppDelegate implementation
// See the protocol definition for details about the methods.
// Note that we're excluding all the optional methods that we aren't using,
// however your needs may be different.
extension AppDelegate: TunneledAppDelegate {
	func getPsiphonConfig() -> Any? {
		// In this example, we're going to retrieve our Psiphon config from a file in the app bundle.
		// Alternatively, it could be a string literal in the code, or whatever makes sense.

		guard let psiphonConfigUrl = Bundle.main.url(forResource: "psiphon-config", withExtension: "json") else {
			NSLog("Error getting Psiphon config resource file URL!")
			return nil
		}

		do {
			return try String.init(contentsOf: psiphonConfigUrl)
		} catch {
			NSLog("Error reading Psiphon config resource file!")
			return nil
		}
	}

    /// Read the Psiphon embedded server entries resource file and return the contents.
    /// * returns: The string of the contents of the file.
    func getEmbeddedServerEntries() -> String? {
        guard let psiphonEmbeddedServerEntriesUrl = Bundle.main.url(forResource: "psiphon-embedded-server-entries", withExtension: "txt") else {
            NSLog("Error getting Psiphon embedded server entries resource file URL!")
            return nil
        }

        do {
            return try String.init(contentsOf: psiphonEmbeddedServerEntriesUrl)
        } catch {
            NSLog("Error reading Psiphon embedded server entries resource file!")
            return nil
        }
    }

	func onDiagnosticMessage(_ message: String) {
		NSLog("onDiagnosticMessage: %@", message)
	}

	func onConnected() {
		NSLog("onConnected")

		// After we're connected, make tunneled requests and populate the webview.

		DispatchQueue.global(qos: .default).async {
			// First we'll make a "what is my IP" request via makeRequestViaUrlSessionProxy().
			let url = "https://geoip.nekudo.com/api/"
			self.makeRequestViaUrlSessionProxy(url) {
				(_ result: String?) in

				if result == nil {
					NSLog("Failed to get \(url)")
					return
				}

				// Do a little pretty-printing.
				let prettyResult = result?.replacingOccurrences(of: ",", with: ",\n  ")
					.replacingOccurrences(of: "{", with: "{\n  ")
					.replacingOccurrences(of: "}", with: "\n}")

				DispatchQueue.main.sync {
					// Load the result into the view.
                    let mainView = self.window?.rootViewController as! ViewController
					mainView.appendToView("Result from \(url):\n\(prettyResult!)")
				}

				// Then we'll make a different "what is my IP" request via makeRequestViaUrlProxy().
				DispatchQueue.global(qos: .default).async {
					let url = "https://ifconfig.co/json"
					self.makeRequestViaUrlProxy(url) {
						(_ result: String?) in

						if result == nil {
							NSLog("Failed to get \(url)")
							return
						}

						// Do a little pretty-printing.
						let prettyResult = result?.replacingOccurrences(of: ",", with: ",\n  ")
							.replacingOccurrences(of: "{", with: "{\n  ")
							.replacingOccurrences(of: "}", with: "\n}")

						DispatchQueue.main.sync {
							// Load the result into the view.
                            let mainView = self.window?.rootViewController as! ViewController
							mainView.appendToView("Result from \(url):\n\(prettyResult!)")
						}

						// We'll leave the tunnel open for when we want to make
						// more requests. It will get stopped by `applicationWillTerminate`.
					}
				}

			}
		}
	}
}
