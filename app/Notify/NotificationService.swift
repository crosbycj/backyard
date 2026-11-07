import UserNotifications

/// Before a notification shows: the visit's photo, from the feed, so the
/// Lock Screen has the bird and a long press shows it big. If the photo
/// doesn't come in time, the words go alone.
final class NotificationService: UNNotificationServiceExtension {
    private var done: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler done: @escaping (UNNotificationContent) -> Void) {
        self.done = done
        let content = request.content.mutableCopy() as? UNMutableNotificationContent
        self.content = content
        guard let content, let address = content.userInfo["image"] as? String, let url = URL(string: address) else {
            done(request.content)
            return
        }
        URLSession.shared.downloadTask(with: url) { file, response, _ in
            defer { done(content) }
            guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            // The attachment needs its kind in the name.
            let photo = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".jpg")
            guard (try? FileManager.default.moveItem(at: file, to: photo)) != nil,
                  let attachment = try? UNNotificationAttachment(identifier: "photo", url: photo) else { return }
            content.attachments = [attachment]
        }.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        if let done, let content { done(content) }
    }
}
