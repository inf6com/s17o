//
//  SafariWebExtensionHandler.swift
//  s17o Extension
//
//  Created by decopin on 2026/04/09.
//

import SafariServices
import os.log

private let pageSnapshotNotification = Notification.Name("s17oPageSnapshot")
private let extensionLog = OSLog(subsystem: "s17o", category: "SafariWebExtension")

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem

        let profile: UUID?
        if #available(iOS 17.0, macOS 14.0, *) {
            profile = request?.userInfo?[SFExtensionProfileKey] as? UUID
        } else {
            profile = request?.userInfo?["profile"] as? UUID
        }

        let message: Any?
        if #available(iOS 15.0, macOS 11.0, *) {
            message = request?.userInfo?[SFExtensionMessageKey]
        } else {
            message = request?.userInfo?["message"]
        }

        os_log("Received message from browser.runtime.sendNativeMessage: %{public}@ (profile: %{public}@)", log: extensionLog, type: .info, String(describing: message), profile?.uuidString ?? "none")

        let responsePayload: [String: Any]
        if let messageDictionary = message as? [String: Any],
           let type = messageDictionary["type"] as? String,
           type == "pageSnapshot" || type == "tabCatalog" {
            responsePayload = handleBrowserMessage(messageDictionary)
        } else {
            responsePayload = [
                "ok": false,
                "error": "Unsupported native message",
            ]
        }

        let complete = {
            let response = NSExtensionItem()
            if #available(iOS 15.0, macOS 11.0, *) {
                response.userInfo = [SFExtensionMessageKey: responsePayload]
            } else {
                response.userInfo = ["message": responsePayload]
            }

            context.completeRequest(returningItems: [response], completionHandler: nil)
        }

        if Thread.isMainThread {
            complete()
        } else {
            DispatchQueue.main.async(execute: complete)
        }
    }

    private func handleBrowserMessage(_ payload: [String: Any]) -> [String: Any] {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            guard let json = String(data: data, encoding: .utf8) else {
                return [
                    "ok": false,
                    "error": "Unable to encode browser message",
                ]
            }

            let postNotification = {
                DistributedNotificationCenter.default().postNotificationName(
                    pageSnapshotNotification,
                    object: nil,
                    userInfo: ["payload": json],
                    deliverImmediately: true
                )
            }

            if Thread.isMainThread {
                postNotification()
            } else {
                DispatchQueue.main.sync(execute: postNotification)
            }

            return [
                "ok": true,
            ]
        } catch {
            os_log("Failed to handle browser message: %{public}@", log: extensionLog, type: .error, error.localizedDescription)
            return [
                "ok": false,
                "error": error.localizedDescription,
            ]
        }
    }
}

extension SafariWebExtensionHandler: SFSafariExtensionHandling {
    func messageReceivedFromContainingApp(withName messageName: String, userInfo: [String : Any]? = nil) {
        _ = handleBrowserMessage([
            "type": "extensionHandshake",
            "name": messageName,
            "sentAt": Date().timeIntervalSince1970
        ])
        postTabCatalogFromSafariAPI()
    }

    private func postTabCatalogFromSafariAPI() {
        guard #available(macOS 10.14.4, *) else { return }
        SFSafariApplication.getAllWindows { windows in
            guard !windows.isEmpty else {
                SafariWebExtensionHandler.postTabCatalogNotification([])
                return
            }
            var results: [[String: Any]] = []
            var remaining = windows.count

            func done() {
                remaining -= 1
                if remaining == 0 {
                    SafariWebExtensionHandler.postTabCatalogNotification(results)
                }
            }

            for (wIdx, window) in windows.enumerated() {
                window.getActiveTab { tab in
                    guard let tab else { done(); return }
                    tab.getActivePage { page in
                        guard let page else { done(); return }
                        page.getPropertiesWithCompletionHandler { props in
                            if let url = props?.url?.absoluteString, !url.isEmpty {
                                results.append([
                                    "id": (wIdx + 1) << 16,
                                    "title": props?.title ?? "",
                                    "url": url,
                                    "active": true,
                                    "isFocusedWindow": wIdx == 0
                                ])
                            }
                            done()
                        }
                    }
                }
            }
        }
    }

    private static func postTabCatalogNotification(_ tabs: [[String: Any]]) {
        let payload: [String: Any] = [
            "type": "tabCatalog",
            "reason": "healthCheck",
            "sentAt": Date().timeIntervalSince1970 * 1000,
            "tabs": tabs
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            pageSnapshotNotification,
            object: nil,
            userInfo: ["payload": json],
            deliverImmediately: true
        )
    }
}
