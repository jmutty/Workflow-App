import Foundation
import AppKit

struct GitHubRelease: Codable {
    let tagName: String
    let assets: [GitHubAsset]
    let htmlUrl: String
    let body: String
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
        case htmlUrl = "html_url"
        case body
    }
}

struct GitHubAsset: Codable {
    let url: String
    let browserDownloadUrl: String
    let name: String
    
    enum CodingKeys: String, CodingKey {
        case url
        case browserDownloadUrl = "browser_download_url"
        case name
    }
}

class UpdateService: NSObject, ObservableObject, URLSessionTaskDelegate {
    static let shared = UpdateService()
    
    @Published var isUpdateAvailable = false
    @Published var latestRelease: GitHubRelease?
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    
    private let fileManager = FileManager.default
    
    func checkForUpdates() {
        let urlString = "https://api.github.com/repos/\(Constants.GitHub.repoOwner)/\(Constants.GitHub.repoName)/releases/latest"
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(Secrets.GitHub.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        
        // Check update needs simple task
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, let data = data, error == nil else {
                print("Update check failed: \(error?.localizedDescription ?? "Unknown error")")
                return
            }
            
            do {
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                DispatchQueue.main.async {
                    self.compareVersions(release: release)
                }
            } catch {
                print("Failed to decode release info: \(error)")
            }
        }
        task.resume()
    }
    
    private func compareVersions(release: GitHubRelease) {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        
        // Remove 'v' prefix if present for comparison
        let cleanTag = release.tagName.replacingOccurrences(of: "v", with: "")
        let cleanCurrent = currentVersion.replacingOccurrences(of: "v", with: "")
        
        if cleanTag.compare(cleanCurrent, options: .numeric) == .orderedDescending {
            self.latestRelease = release
            self.isUpdateAvailable = true
        }
    }
    
    func downloadAndInstall() {
        guard let release = latestRelease,
              let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            print("No suitable asset found for update")
            return
        }
        
        // Use the API URL which handles Auth + Redirect correctly if handled right
        guard let url = URL(string: asset.url) else { return }
        
        isDownloading = true
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(Secrets.GitHub.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        
        // Use custom session to handle redirect delegate
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        
        let task = session.downloadTask(with: request) { [weak self] localUrl, response, error in
            guard let self = self else { return }
            
            if let httpResponse = response as? HTTPURLResponse {
                print("📥 Download Status: \(httpResponse.statusCode)")
            }
            
            guard let localUrl = localUrl, error == nil else {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    print("Download failed: \(error?.localizedDescription ?? "Unknown")")
                }
                return
            }
            
            // Move to temporary location with correct name
            let tempDir = self.fileManager.temporaryDirectory
            let zipTarget = tempDir.appendingPathComponent(asset.name)
            
            do {
                if self.fileManager.fileExists(atPath: zipTarget.path) {
                    try self.fileManager.removeItem(at: zipTarget)
                }
                try self.fileManager.moveItem(at: localUrl, to: zipTarget)
                
                print("✅ Downloaded to: \(zipTarget.path)")
                // Now install it
                self.installUpdate(zipPath: zipTarget.path)
            } catch {
                print("File handling error: \(error)")
                DispatchQueue.main.async {
                    self.isDownloading = false
                }
            }
        }
        task.resume()
    }
    
    // MARK: - URLSessionTaskDelegate
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // When redirected (e.g. to S3), we MUST STRIP the Authorization header
        // otherwise S3 rejects the signed URL request with 400 Bad Request
        var newRequest = request
        newRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(newRequest)
    }
    
    private func installUpdate(zipPath: String) {
        // 1. Unzip
        // 2. Quit this app
        // 3. Launch helper script to swap apps and relaunch
        
        let appBundlePath = Bundle.main.bundlePath
        let appName = (appBundlePath as NSString).lastPathComponent
        let appParentDir = (appBundlePath as NSString).deletingLastPathComponent
        
        // We'll unzip to a unique temp directory
        let unzipDir = (zipPath as NSString).deletingLastPathComponent
        
        // Script to run detached
        // It waits for us to quit, then deletes old app, moves new one in, opens it
        let script = """
        LOG="/Users/207photo/Desktop/update_log.txt"
        echo "$(date): Starting update process" > "$LOG"
        echo "Zip Path: \(zipPath)" >> "$LOG"
        echo "App Path: \(appBundlePath)" >> "$LOG"
        
        sleep 2
        
        cd "\(unzipDir)"
        echo "Unzipping..." >> "$LOG"
        /usr/bin/unzip -o "\(zipPath)" >> "$LOG" 2>&1
        
        echo "Removing old app at \(appBundlePath)..." >> "$LOG"
        rm -rf "\(appBundlePath)" >> "$LOG" 2>&1
        if [ $? -ne 0 ]; then echo "FAILED to remove old app" >> "$LOG"; exit 1; fi
        
        echo "Moving new app..." >> "$LOG"
        mv "\(appName)" "\(appParentDir)/" >> "$LOG" 2>&1
        if [ $? -ne 0 ]; then echo "FAILED to move new app" >> "$LOG"; exit 1; fi
        
        echo "Removing quarantine..." >> "$LOG"
        xattr -cr "\(appBundlePath)" >> "$LOG" 2>&1
        
        echo "Launching new app..." >> "$LOG"
        open "\(appBundlePath)" >> "$LOG" 2>&1
        echo "Done" >> "$LOG"
        """
        
        let process = Process()
        process.launchPath = "/bin/sh"
        process.arguments = ["-c", script]
        
        do {
            try process.run()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        } catch {
            print("Failed to run update script: \(error)")
            DispatchQueue.main.async {
                self.isDownloading = false
            }
        }
    }
}
