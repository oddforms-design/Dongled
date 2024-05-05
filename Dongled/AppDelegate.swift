//
//  AppDelegate.swift
//  Dongle
//
//  Created by Charles Sheppa on 9/6/23.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var isInitialLaunch = true
    var sessionBlocked: Bool = false
    let viewController = ViewController()
    let audioManager = AudioManager()
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Listen for resign
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        // Listen for resume
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
        return true
    }
    
    // MARK: AppSession Lifecycle
    func applicationDidBecomeActive(_ application: UIApplication) {
        if isInitialLaunch {
            isInitialLaunch = false
            return  // Exit early if initial launch
        }
        if sessionBlocked { // Session was unplugged outside the app
            print("App became active. Attempting to discover and reconnect session.")
            viewController.rebootSession()
            sessionBlocked = false
        } else {
            // Session was not unplugged, but app resigned, resuming
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // Delay for device needed to prevent audio drop
                self.audioManager.startAudio()
                self.viewController.startSession()
                print("Session Resumed Unblocked Active")
            }
        }
    }
    
     func applicationWillResignActive(_ application: UIApplication) {
                self.audioManager.pauseAudio()
                self.viewController.sessionStop()
                print("Session Resigned Active")
            
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        // Remove observers
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
    
    


}

