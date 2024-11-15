//
//  Adobe Downloader
//
//  Created by X1a0He on 2024/10/30.
//
import Foundation
import Network
import Combine
import AppKit

class DownloadUtils {
    typealias ProgressUpdate = (bytesWritten: Int64, totalWritten: Int64, expectedToWrite: Int64)

    private weak var networkManager: NetworkManager?
    private let cancelTracker: CancelTracker

    init(networkManager: NetworkManager, cancelTracker: CancelTracker) {
        self.networkManager = networkManager
        self.cancelTracker = cancelTracker
    }

    private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        var completionHandler: (URL?, URLResponse?, Error?) -> Void
        var progressHandler: ((Int64, Int64, Int64) -> Void)?
        var destinationDirectory: URL
        var fileName: String
        private var hasCompleted = false
        private let completionLock = NSLock()
        private var lastUpdateTime = Date()
        private var lastBytes: Int64 = 0

        init(destinationDirectory: URL,
             fileName: String,
             completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void,
             progressHandler: ((Int64, Int64, Int64) -> Void)? = nil) {
            self.destinationDirectory = destinationDirectory
            self.fileName = fileName
            self.completionHandler = completionHandler
            self.progressHandler = progressHandler
            super.init()
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            completionLock.lock()
            defer { completionLock.unlock() }

            guard !hasCompleted else { return }
            hasCompleted = true

            do {
                if !FileManager.default.fileExists(atPath: destinationDirectory.path) {
                    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                }

                let destinationURL = destinationDirectory.appendingPathComponent(fileName)

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }

                try FileManager.default.moveItem(at: location, to: destinationURL)
                completionHandler(destinationURL, downloadTask.response, nil)

            } catch {
                print("File operation error in delegate: \(error.localizedDescription)")
                completionHandler(nil, downloadTask.response, error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            completionLock.lock()
            defer { completionLock.unlock() }

            guard !hasCompleted else { return }
            hasCompleted = true

            if let error = error {
                switch (error as NSError).code {
                case NSURLErrorCancelled:
                    return
                case NSURLErrorTimedOut:
                    completionHandler(nil, task.response, NetworkError.downloadError("下载超时", error))
                case NSURLErrorNotConnectedToInternet:
                    completionHandler(nil, task.response, NetworkError.noConnection)
                default:
                    completionHandler(nil, task.response, error)
                }
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                       didWriteData bytesWritten: Int64,
                       totalBytesWritten: Int64,
                       totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            guard bytesWritten > 0 else { return }
            
            handleProgressUpdate(
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpectedToWrite: totalBytesExpectedToWrite
            )
        }

        func cleanup() {
            completionHandler = { _, _, _ in }
            progressHandler = nil
        }

        private func handleProgressUpdate(bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let now = Date()
            let timeDiff = now.timeIntervalSince(lastUpdateTime)
            
            guard timeDiff >= NetworkConstants.progressUpdateInterval else { return }

            progressHandler?(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
            
            lastUpdateTime = now
            lastBytes = totalBytesWritten
        }
    }

    func pauseDownloadTask(taskId: UUID, reason: DownloadStatus.PauseInfo.PauseReason) async {
        let task = await cancelTracker.downloadTasks[taskId]
        if let downloadTask = task {
            let data = await withCheckedContinuation { continuation in
                downloadTask.cancel(byProducingResumeData: { data in
                    continuation.resume(returning: data)
                })
            }
            if let data = data {
                await cancelTracker.storeResumeData(taskId, data: data)
            }
        }

        await MainActor.run {
            if let task = networkManager?.downloadTasks.first(where: { $0.id == taskId }) {
                task.setStatus(.paused(DownloadStatus.PauseInfo(
                    reason: reason,
                    timestamp: Date(),
                    resumable: true
                )))
                networkManager?.saveTask(task)
            }
        }
    }

    func resumeDownloadTask(taskId: UUID) async {
        if let task = await networkManager?.downloadTasks.first(where: { $0.id == taskId }) {
            await startDownloadProcess(task: task)
        }
    }

    func cancelDownloadTask(taskId: UUID, removeFiles: Bool = false) async {
        await cancelTracker.cancel(taskId)

        await MainActor.run {
            if let task = networkManager?.downloadTasks.first(where: { $0.id == taskId }) {
                if removeFiles {
                    try? FileManager.default.removeItem(at: task.directory)
                }

                task.setStatus(.failed(DownloadStatus.FailureInfo(
                    message: "下载已取消",
                    error: NetworkError.downloadCancelled,
                    timestamp: Date(),
                    recoverable: false
                )))

                networkManager?.updateDockBadge()
                networkManager?.objectWillChange.send()
            }
        }
    }

    func signApp(at url: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", url.path]
        try process.run()
        process.waitUntilExit()
    }

    func generateDriverXML(sapCode: String, version: String, language: String, productInfo: Sap.Versions, displayName: String) -> String {
        let dependencies = productInfo.dependencies.map { dependency in
            """
                <Dependency>
                    <SAPCode>\(dependency.sapCode)</SAPCode>
                    <BaseVersion>\(dependency.version)</BaseVersion>
                    <EsdDirectory>\(dependency.sapCode)</EsdDirectory>
                </Dependency>
            """
        }.joined(separator: "\n")

        return """
        <DriverInfo>
            <ProductInfo>
                <Name>Adobe \(displayName)</Name>
                <SAPCode>\(sapCode)</SAPCode>
                <CodexVersion>\(version)</CodexVersion>
                <Platform>\(productInfo.apPlatform)</Platform>
                <EsdDirectory>\(sapCode)</EsdDirectory>
                <Dependencies>
                    \(dependencies)
                </Dependencies>
            </ProductInfo>
            <RequestInfo>
                <InstallDir>/Applications</InstallDir>
                <InstallLanguage>\(language)</InstallLanguage>
            </RequestInfo>
        </DriverInfo>
        """
    }

    private func executePrivilegedCommand(_ command: String) async throws -> String {
        return await withCheckedContinuation { continuation in
            PrivilegedHelperManager.shared.executeCommand(command) { result in
                if result.starts(with: "Error:") {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func downloadPackage(package: Package, task: NewDownloadTask, product: ProductsToDownload, url: URL? = nil, resumeData: Data? = nil) async throws {
        var lastUpdateTime = Date()
        var lastBytes: Int64 = 0

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                destinationDirectory: task.directory.appendingPathComponent(product.sapCode),
                fileName: package.fullPackageName,
                completionHandler: { [weak networkManager] localURL, response, error in
                    if let error = error {
                        if (error as NSError).code == NSURLErrorCancelled {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }

                    Task { @MainActor in
                        package.downloadedSize = package.downloadSize
                        package.progress = 1.0
                        package.status = .completed
                        package.downloaded = true

                        var totalDownloaded: Int64 = 0
                        var totalSize: Int64 = 0

                        for prod in task.productsToDownload {
                            for pkg in prod.packages {
                                totalSize += pkg.downloadSize
                                if pkg.downloaded {
                                    totalDownloaded += pkg.downloadSize
                                }
                            }
                        }

                        task.totalSize = totalSize
                        task.totalDownloadedSize = totalDownloaded
                        task.totalProgress = Double(totalDownloaded) / Double(totalSize)
                        task.totalSpeed = 0

                        let allCompleted = task.productsToDownload.allSatisfy {
                            product in product.packages.allSatisfy { $0.downloaded }
                        }

                        if allCompleted {
                            task.setStatus(.completed(DownloadStatus.CompletionInfo(
                                timestamp: Date(),
                                totalTime: Date().timeIntervalSince(task.createAt),
                                totalSize: totalSize
                            )))
                        }

                        product.updateCompletedPackages()
                        networkManager?.saveTask(task)
                        networkManager?.objectWillChange.send()
                    }

                    continuation.resume()
                },
                progressHandler: { [weak networkManager] bytesWritten, totalBytesWritten, totalBytesExpectedToWrite in
                    Task { @MainActor in
                        let now = Date()
                        let timeDiff = now.timeIntervalSince(lastUpdateTime)

                        if timeDiff >= 1.0 {
                            let bytesDiff = totalBytesWritten - lastBytes
                            let speed = Double(bytesDiff) / timeDiff

                            package.updateProgress(
                                downloadedSize: totalBytesWritten,
                                speed: speed
                            )

                            var totalDownloaded: Int64 = 0
                            var totalSize: Int64 = 0
                            var currentSpeed: Double = 0

                            for prod in task.productsToDownload {
                                for pkg in prod.packages {
                                    totalSize += pkg.downloadSize
                                    if pkg.downloaded {
                                        totalDownloaded += pkg.downloadSize
                                    } else if pkg.id == package.id {
                                        totalDownloaded += totalBytesWritten
                                        currentSpeed = speed
                                    }
                                }
                            }

                            task.totalSize = totalSize
                            task.totalDownloadedSize = totalDownloaded
                            task.totalProgress = totalSize > 0 ? Double(totalDownloaded) / Double(totalSize) : 0
                            task.totalSpeed = currentSpeed

                            lastUpdateTime = now
                            lastBytes = totalBytesWritten

                            networkManager?.objectWillChange.send()
                        }
                    }
                }
            )

            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

            Task {
                let downloadTask: URLSessionDownloadTask
                if let resumeData = resumeData {
                    downloadTask = session.downloadTask(withResumeData: resumeData)
                } else if let url = url {
                    var request = URLRequest(url: url)
                    NetworkConstants.downloadHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                    downloadTask = session.downloadTask(with: request)
                } else {
                    continuation.resume(throwing: NetworkError.invalidData("Neither URL nor resume data provided"))
                    return
                }

                await cancelTracker.registerTask(task.id, task: downloadTask, session: session)
                await cancelTracker.clearResumeData(task.id)
                downloadTask.resume()
            }
        }
    }

    private func startDownloadProcess(task: NewDownloadTask) async {
        actor DownloadProgress {
            var currentPackageIndex: Int = 0
            func increment() { currentPackageIndex += 1 }
            func get() -> Int { return currentPackageIndex }
        }

        let progress = DownloadProgress()

        await MainActor.run {
            let totalPackages = task.productsToDownload.reduce(0) { $0 + $1.packages.count }
            task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                fileName: task.currentPackage?.fullPackageName ?? "",
                currentPackageIndex: 0,
                totalPackages: totalPackages,
                startTime: Date(),
                estimatedTimeRemaining: nil
            )))
            task.objectWillChange.send()
        }

        let driverPath = task.directory.appendingPathComponent("driver.xml")
        if !FileManager.default.fileExists(atPath: driverPath.path) {
            if let productInfo = await networkManager?.saps[task.sapCode]?.versions[task.version] {
                let driverXml = generateDriverXML(
                    sapCode: task.sapCode,
                    version: task.version,
                    language: task.language,
                    productInfo: productInfo,
                    displayName: task.displayName
                )
                do {
                    try driverXml.write(to: driverPath, atomically: true, encoding: .utf8)
                } catch {
                    print("Error generating driver.xml:", error.localizedDescription)
                    await MainActor.run {
                        task.setStatus(.failed(DownloadStatus.FailureInfo(
                            message: "生成 driver.xml 失败: \(error.localizedDescription)",
                            error: error,
                            timestamp: Date(),
                            recoverable: false
                        )))
                    }
                    return
                }
            }
        }

        for product in task.productsToDownload {
            let productDir = task.directory.appendingPathComponent(product.sapCode)
            if !FileManager.default.fileExists(atPath: productDir.path) {
                do {
                    try FileManager.default.createDirectory(
                        at: productDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                } catch {
                    print("Error creating directory for \(product.sapCode): \(error)")
                    continue
                }
            }
        }

        for product in task.productsToDownload {
            for package in product.packages where !package.downloaded {
                let currentIndex = await progress.get()

                await MainActor.run {
                    task.currentPackage = package
                    task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                        fileName: package.fullPackageName,
                        currentPackageIndex: currentIndex,
                        totalPackages: task.productsToDownload.reduce(0) { $0 + $1.packages.count },
                        startTime: Date(),
                        estimatedTimeRemaining: nil
                    )))
                    networkManager?.saveTask(task)
                }

                await progress.increment()

                guard !package.fullPackageName.isEmpty,
                      !package.downloadURL.isEmpty,
                      package.downloadSize > 0 else {
                    continue
                }

                let cdn = await networkManager?.cdn ?? ""
                let cleanCdn = cdn.hasSuffix("/") ? String(cdn.dropLast()) : cdn
                let cleanPath = package.downloadURL.hasPrefix("/") ? package.downloadURL : "/\(package.downloadURL)"
                let downloadURL = cleanCdn + cleanPath

                guard let url = URL(string: downloadURL) else { continue }

                do {
                    if let resumeData = await cancelTracker.getResumeData(task.id) {
                        try await downloadPackage(package: package, task: task, product: product, resumeData: resumeData)
                    } else {
                        try await downloadPackage(package: package, task: task, product: product, url: url)
                    }
                } catch {
                    print("Error downloading package \(package.fullPackageName): \(error.localizedDescription)")
                    await handleError(task.id, error)
                    return
                }
            }
        }

        let allPackagesDownloaded = task.productsToDownload.allSatisfy { product in
            product.packages.allSatisfy { $0.downloaded }
        }

        if allPackagesDownloaded {
            await MainActor.run {
                task.setStatus(.completed(DownloadStatus.CompletionInfo(
                    timestamp: Date(),
                    totalTime: Date().timeIntervalSince(task.createAt),
                    totalSize: task.totalSize
                )))
                networkManager?.saveTask(task)
            }
        }
    }

    func retryPackage(task: NewDownloadTask, package: Package) async throws {
        guard package.canRetry else { return }

        package.prepareForRetry()

        if let product = task.productsToDownload.first(where: { $0.packages.contains(where: { $0.id == package.id }) }) {
            await MainActor.run {
                task.currentPackage = package
            }

            if let cdn = await networkManager?.cdnUrl {
                try await downloadPackage(package: package, task: task, product: product, url: URL(string: cdn + package.downloadURL)!)
            } else {
                throw NetworkError.invalidData("无法取 CDN 地址")
            }
        }
    }

    func downloadAPRO(task: NewDownloadTask, productInfo: Sap.Versions) async throws {
        guard let networkManager = networkManager else { return }

        let manifestURL = await networkManager.cdnUrl + productInfo.buildGuid
        guard let url = URL(string: manifestURL) else {
            throw NetworkError.invalidURL(manifestURL)
        }

        var request = URLRequest(url: url)
        NetworkConstants.adobeRequestHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (manifestData, _) = try await URLSession.shared.data(for: request)

        let manifestDoc = try XMLDocument(data: manifestData)

        guard let downloadPath = try manifestDoc.nodes(forXPath: "//asset_list/asset/asset_path").first?.stringValue,
              let assetSizeStr = try manifestDoc.nodes(forXPath: "//asset_list/asset/asset_size").first?.stringValue,
              let assetSize = Int64(assetSizeStr) else {
            throw NetworkError.invalidData("无法从manifest中获取下载信息")
        }

        let aproPackage = Package(
            type: "dmg",
            fullPackageName: "Adobe Downloader \(task.sapCode)_\(productInfo.productVersion)_\(productInfo.apPlatform).dmg",
            downloadSize: assetSize,
            downloadURL: downloadPath
        )

        await MainActor.run {
            let product = ProductsToDownload(
                sapCode: task.sapCode,
                version: task.version,
                buildGuid: productInfo.buildGuid
            )
            product.packages = [aproPackage]
            task.productsToDownload = [product]
            task.totalSize = assetSize
            task.currentPackage = aproPackage
            task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                fileName: aproPackage.fullPackageName,
                currentPackageIndex: 0,
                totalPackages: 1,
                startTime: Date(),
                estimatedTimeRemaining: nil
            )))
        }

        let tempDownloadDir = task.directory.deletingLastPathComponent()

        var lastUpdateTime = Date()
        var lastBytes: Int64 = 0

        let delegate = DownloadDelegate(
            destinationDirectory: tempDownloadDir,
            fileName: aproPackage.fullPackageName,
            completionHandler: { [weak networkManager] (localURL: URL?, response: URLResponse?, error: Error?) in
                if let error = error {
                    print("Download error:", error)
                    return
                }
                Task { @MainActor in
                    aproPackage.downloadedSize = aproPackage.downloadSize
                    aproPackage.progress = 1.0
                    aproPackage.status = .completed
                    aproPackage.downloaded = true

                    var totalDownloaded: Int64 = 0
                    var totalSize: Int64 = 0

                    totalSize += aproPackage.downloadSize
                    if aproPackage.downloaded {
                        totalDownloaded += aproPackage.downloadSize
                    }

                    task.totalSize = totalSize
                    task.totalDownloadedSize = totalDownloaded
                    task.totalProgress = Double(totalDownloaded) / Double(totalSize)
                    task.totalSpeed = 0

                    let allCompleted = task.productsToDownload.allSatisfy { product in
                        product.packages.allSatisfy { $0.downloaded }
                    }

                    if allCompleted {
                        task.setStatus(.completed(DownloadStatus.CompletionInfo(
                            timestamp: Date(),
                            totalTime: Date().timeIntervalSince(task.createAt),
                            totalSize: totalSize
                        )))
                    }

                    task.objectWillChange.send()
                    networkManager?.objectWillChange.send()
                }
            },
            progressHandler: { [weak networkManager] (bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) in
                Task { @MainActor in
                    let now = Date()
                    let timeDiff = now.timeIntervalSince(lastUpdateTime)

                    if timeDiff >= 1.0 {
                        let bytesDiff = totalBytesWritten - lastBytes
                        let speed = Double(bytesDiff) / timeDiff

                        aproPackage.updateProgress(
                            downloadedSize: totalBytesWritten,
                            speed: speed
                        )

                        task.totalDownloadedSize = totalBytesWritten
                        task.totalProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                        task.totalSpeed = speed

                        lastUpdateTime = now
                        lastBytes = totalBytesWritten

                        task.objectWillChange.send()
                        networkManager?.objectWillChange.send()
                    }
                }
            }
        )

        guard let fullURL = URL(string: downloadPath) else {
            throw NetworkError.invalidURL(downloadPath)
        }

        var request2 = URLRequest(url: fullURL)
        NetworkConstants.downloadHeaders.forEach { request2.setValue($0.value, forHTTPHeaderField: $0.key) }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let downloadTask = session.downloadTask(with: request2)
        downloadTask.resume()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let originalCompletionHandler = delegate.completionHandler

            delegate.completionHandler = { (url: URL?, response: URLResponse?, error: Error?) in
                originalCompletionHandler(url, response, error)

                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func handleDownload(task: NewDownloadTask, productInfo: Sap.Versions, allowedPlatform: [String], saps: [String: Sap]) async throws {
        if task.sapCode == "APRO" {
            try await downloadAPRO(task: task, productInfo: productInfo)
            return
        }

        var productsToDownload: [ProductsToDownload] = []

        productsToDownload.append(ProductsToDownload(
            sapCode: task.sapCode,
            version: task.version,
            buildGuid: productInfo.buildGuid
        ))

        for dependency in productInfo.dependencies {
            if let dependencyVersions = saps[dependency.sapCode]?.versions {
                var firstGuid: String?
                var buildGuid: String?

                let sortedVersions = dependencyVersions.sorted { version1, version2 in
                    let v1Components = version1.key.split(separator: ".").compactMap { Int($0) }
                    let v2Components = version2.key.split(separator: ".").compactMap { Int($0) }

                    for i in 0..<min(v1Components.count, v2Components.count) {
                        if v1Components[i] != v2Components[i] {
                            return v1Components[i] > v2Components[i]
                        }
                    }
                    return v1Components.count > v2Components.count
                }

                for version in sortedVersions {
                    if version.value.baseVersion == dependency.version {
                        if firstGuid == nil { firstGuid = version.value.buildGuid }

                        // print("\(version.value.sapCode), \(version.key), \(allowedPlatform), \(version.value.apPlatform), \(allowedPlatform.contains(version.value.apPlatform))")

                        if allowedPlatform.contains(version.value.apPlatform) {
                            buildGuid = version.value.buildGuid
                            break
                        }
                    }
                }

                if buildGuid == nil { buildGuid = firstGuid }
                if let finalBuildGuid = buildGuid {
                    productsToDownload.append(ProductsToDownload(
                        sapCode: dependency.sapCode,
                        version: dependency.version,
                        buildGuid: finalBuildGuid
                    ))
                }
            }
        }

//        for product in productsToDownload {
//            print("\(product.sapCode), \(product.version), \(product.buildGuid)")
//        }

        for product in productsToDownload {
            await MainActor.run {
                task.setStatus(.preparing(DownloadStatus.PrepareInfo(
                    message: String(localized: "正在处理 \(product.sapCode) 的包信息..."),
                    timestamp: Date(),
                    stage: .fetchingInfo
                )))
            }

            let jsonString = try await getApplicationInfo(buildGuid: product.buildGuid)
            let productDir = task.directory.appendingPathComponent("\(product.sapCode)")
            if !FileManager.default.fileExists(atPath: productDir.path) {
                try FileManager.default.createDirectory(at: productDir, withIntermediateDirectories: true)
            }
            let jsonURL = productDir.appendingPathComponent("application.json")
            try jsonString.write(to: jsonURL, atomically: true, encoding: .utf8)

            guard let jsonData = jsonString.data(using: .utf8),
                  let appInfo = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let packages = appInfo["Packages"] as? [String: Any],
                  let packageArray = packages["Package"] as? [[String: Any]] else {
                throw NetworkError.invalidData("无法解析产品信息")
            }

            var corePackageCount = 0
            var nonCorePackageCount = 0
            
            for package in packageArray {
                let packageType = package["Type"] as? String ?? "non-core"
                let isCore = packageType == "core"

                guard let downloadURL = package["Path"] as? String, !downloadURL.isEmpty else { continue }

                let fullPackageName: String
                if let name = package["fullPackageName"] as? String, !name.isEmpty {
                    fullPackageName = name
                } else if let name = package["PackageName"] as? String, !name.isEmpty {
                    fullPackageName = "\(name).zip"
                } else { continue }

                let downloadSize: Int64
                if let sizeNumber = package["DownloadSize"] as? NSNumber {
                    downloadSize = sizeNumber.int64Value
                } else if let sizeString = package["DownloadSize"] as? String,
                          let parsedSize = Int64(sizeString) {
                    downloadSize = parsedSize
                } else if let sizeInt = package["DownloadSize"] as? Int {
                    downloadSize = Int64(sizeInt)
                } else { continue }
                
                if isCore {
                    corePackageCount += 1
                    let newPackage = Package(
                        type: packageType,
                        fullPackageName: fullPackageName,
                        downloadSize: downloadSize,
                        downloadURL: downloadURL
                    )
                    product.packages.append(newPackage)
                } else {
                    let languageIsSuitable: Bool
                    if task.language == "ALL" {
                        languageIsSuitable = true
                    } else if !package.keys.contains("Condition") {
                        languageIsSuitable = true
                    } else if let condition = package["Condition"] as? String {
                        let matchesTaskLang = condition.contains("[installLanguage]==\(task.language)")
                        let matchesOSLang = condition.contains("[installLanguage]==en_US")
                        languageIsSuitable = matchesTaskLang || matchesOSLang
                    } else {
                        languageIsSuitable = false
                    }
                    
                    if languageIsSuitable {
                        nonCorePackageCount += 1
                        let newPackage = Package(
                            type: packageType,
                            fullPackageName: fullPackageName,
                            downloadSize: downloadSize,
                            downloadURL: downloadURL
                        )
                        product.packages.append(newPackage)
                    } else {
                    }
                }
            }
        }

        let finalProducts = productsToDownload
        let totalSize = finalProducts.reduce(0) { productSum, product in
            productSum + product.packages.reduce(0) { packageSum, pkg in
                packageSum + (pkg.downloadSize > 0 ? pkg.downloadSize : 0)
            }
        }

        await MainActor.run {
            task.productsToDownload = finalProducts
            task.totalSize = totalSize
        }

        await startDownloadProcess(task: task)
    }

    func getApplicationInfo(buildGuid: String) async throws -> String {
        guard let url = URL(string: NetworkConstants.applicationJsonURL) else {
            throw NetworkError.invalidURL(NetworkConstants.applicationJsonURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        var headers = NetworkConstants.adobeRequestHeaders
        headers["x-adobe-build-guid"] = buildGuid
        headers["Cookie"] = await networkManager?.generateCookie() ?? ""

        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.httpError(httpResponse.statusCode, String(data: data, encoding: .utf8))
        }

        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw NetworkError.invalidData(String(localized: "无法将响应数据转换为json字符串"))
        }

        return jsonString
    }

    func handleError(_ taskId: UUID, _ error: Error) async {
        guard let task = await networkManager?.downloadTasks.first(where: { $0.id == taskId }) else { return }

        let (errorMessage, isRecoverable) = classifyError(error)

        if isRecoverable && task.retryCount < NetworkConstants.maxRetryAttempts {
            task.retryCount += 1
            let nextRetryDate = Date().addingTimeInterval(TimeInterval(NetworkConstants.retryDelay / 1_000_000_000))
            task.setStatus(.retrying(DownloadStatus.RetryInfo(
                attempt: task.retryCount,
                maxAttempts: NetworkConstants.maxRetryAttempts,
                reason: errorMessage,
                nextRetryDate: nextRetryDate
            )))

            Task {
                do {
                    try await Task.sleep(nanoseconds: NetworkConstants.retryDelay)
                    if await !cancelTracker.isCancelled(taskId) {
                        await resumeDownloadTask(taskId: taskId)
                    }
                } catch {
                    print("Retry cancelled for task: \(taskId)")
                }
            }
        } else {
            await MainActor.run {
                task.setStatus(.failed(DownloadStatus.FailureInfo(
                    message: errorMessage,
                    error: error,
                    timestamp: Date(),
                    recoverable: isRecoverable
                )))

                if let currentPackage = task.currentPackage {
                    let destinationDir = task.directory
                        .appendingPathComponent("\(task.sapCode)")
                    let fileURL = destinationDir.appendingPathComponent(currentPackage.fullPackageName)
                    try? FileManager.default.removeItem(at: fileURL)
                }

                networkManager?.saveTask(task)
                networkManager?.updateDockBadge()
                networkManager?.objectWillChange.send()
            }
        }
    }

    private func classifyError(_ error: Error) -> (message: String, recoverable: Bool) {
        switch error {
        case let networkError as NetworkError:
            switch networkError {
            case .noConnection:
                    return (String(localized: "网络连接已断开"), true)
            case .timeout:
                return (String(localized: "下载超时"), true)
            case .serverUnreachable:
                return (String(localized: "服务器无法访问"), true)
            case .insufficientStorage:
                return (String(localized: "存储空间不足"), false)
            case .filePermissionDenied:
                return (String(localized: "没有写入权限"), false)
            default:
                return (networkError.localizedDescription, false)
            }
        case let urlError as URLError:
            switch urlError.code {
            case .notConnectedToInternet:
                return (String(localized: "网络连接已断开"), true)
            case .timedOut:
                return (String(localized: "连接超时"), true)
            case .cancelled:
                return (String(localized: "下载已取消"), false)
            default:
                return (urlError.localizedDescription, true)
            }
        default:
            return (error.localizedDescription, false)
        }
    }

    @MainActor
    func updateProgress(for taskId: UUID, progress: ProgressUpdate) {
        guard let task = networkManager?.downloadTasks.first(where: { $0.id == taskId }),
              let currentPackage = task.currentPackage else { return }

        let now = Date()
        let timeDiff = now.timeIntervalSince(currentPackage.lastUpdated)

        if timeDiff >= NetworkConstants.progressUpdateInterval {
            currentPackage.updateProgress(
                downloadedSize: progress.totalWritten,
                speed: Double(progress.bytesWritten)
            )

            let totalDownloaded = task.productsToDownload.reduce(Int64(0)) { sum, prod in
                sum + prod.packages.reduce(Int64(0)) { sum, pkg in
                    if pkg.downloaded {
                        return sum + pkg.downloadSize
                    } else if pkg.id == currentPackage.id {
                        return sum + progress.totalWritten
                    }
                    return sum
                }
            }

            task.totalDownloadedSize = totalDownloaded
            task.totalProgress = Double(totalDownloaded) / Double(task.totalSize)
            task.totalSpeed = currentPackage.speed

            currentPackage.lastRecordedSize = progress.totalWritten
            currentPackage.lastUpdated = now

            task.objectWillChange.send()
            networkManager?.objectWillChange.send()
        }
    }

    @MainActor
    func updateTaskStatus(_ taskId: UUID, _ status: DownloadStatus) async {
        guard let networkManager = networkManager else { return }

        if let index = networkManager.downloadTasks.firstIndex(where: { $0.id == taskId }) {
            networkManager.downloadTasks[index].setStatus(status)

            switch status {
            case .completed, .failed:
                networkManager.progressObservers[taskId]?.invalidate()
                networkManager.progressObservers.removeValue(forKey: taskId)
                if networkManager.activeDownloadTaskId == taskId {
                    networkManager.activeDownloadTaskId = nil
                }

            case .downloading:
                networkManager.activeDownloadTaskId = taskId

            case .paused:
                if networkManager.activeDownloadTaskId == taskId {
                    networkManager.activeDownloadTaskId = nil
                }

            default:
                break
            }

            networkManager.updateDockBadge()
            networkManager.objectWillChange.send()
        }
    }

    func downloadX1a0HeCCPackages(
        progressHandler: @escaping (Double, String) -> Void,
        cancellationHandler: @escaping () -> Bool
    ) async throws {
        let baseUrl = "https://cdn-ffc.oobesaas.adobe.com/core/v1/applications?name=CreativeCloud&platform=\(AppStatics.isAppleSilicon ? "macarm64" : "osx10")"

        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = NetworkConstants.downloadHeaders
        let session = URLSession(configuration: configuration)
        
        do {
            var request = URLRequest(url: URL(string: baseUrl)!)
            NetworkConstants.downloadHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw NetworkError.invalidResponse
            }
            
            let xmlDoc = try XMLDocument(data: data)

            let packageSets = try xmlDoc.nodes(forXPath: "//packageSet[name='ADC']")
            guard let adcPackageSet = packageSets.first else {
                throw NetworkError.invalidData("找不到ADC包集")
            }

            let targetPackages = ["HDBox", "IPCBox"]
            var packagesToDownload: [(name: String, url: URL, size: Int64)] = []
            
            for packageName in targetPackages {
                let packageNodes = try adcPackageSet.nodes(forXPath: ".//package[name='\(packageName)']")
                guard let package = packageNodes.first else {
                    print("未找到包: \(packageName)")
                    continue
                }

                guard let manifestUrl = try package.nodes(forXPath: ".//manifestUrl").first?.stringValue,
                      let cdnBase = try xmlDoc.nodes(forXPath: "//cdn/secure").first?.stringValue else {
                    print("无法获取manifest URL或CDN基础URL")
                    continue
                }

                let manifestFullUrl = cdnBase + manifestUrl
                
                var manifestRequest = URLRequest(url: URL(string: manifestFullUrl)!)
                NetworkConstants.downloadHeaders.forEach { manifestRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
                let (manifestData, manifestResponse) = try await session.data(for: manifestRequest)
                
                guard let manifestHttpResponse = manifestResponse as? HTTPURLResponse,
                      (200...299).contains(manifestHttpResponse.statusCode) else {
                    print("获取manifest失败: HTTP \(String(describing: (manifestResponse as? HTTPURLResponse)?.statusCode))")
                    continue
                }
                
                #if DEBUG
                if let manifestString = String(data: manifestData, encoding: .utf8) {
                    print("Manifest内容: \(manifestString)")
                }
                #endif
                let manifestDoc = try XMLDocument(data: manifestData)
                let assetPathNodes = try manifestDoc.nodes(forXPath: "//asset_path")
                let sizeNodes = try manifestDoc.nodes(forXPath: "//asset_size")
                guard let assetPath = assetPathNodes.first?.stringValue,
                      let sizeStr = sizeNodes.first?.stringValue,
                      let size = Int64(sizeStr),
                      let downloadUrl = URL(string: assetPath) else {
                    continue
                }
                packagesToDownload.append((packageName, downloadUrl, size))
            }
            
            guard !packagesToDownload.isEmpty else {
                throw NetworkError.invalidData("没有找到可下载的包")
            }

            let totalCount = packagesToDownload.count
            for (index, package) in packagesToDownload.enumerated() {
                if cancellationHandler() {
                    try? FileManager.default.removeItem(at: tempDirectory)
                    throw NetworkError.cancelled
                }
                
                await MainActor.run {
                    progressHandler(Double(index) / Double(totalCount), "正在下载 \(package.name)...")
                }

                let destinationURL = tempDirectory.appendingPathComponent("\(package.name).zip")
                var downloadRequest = URLRequest(url: package.url)
                NetworkConstants.downloadHeaders.forEach { downloadRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
                let (downloadURL, downloadResponse) = try await session.download(for: downloadRequest)
                
                guard let httpResponse = downloadResponse as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    print("下载失败: HTTP \(String(describing: (downloadResponse as? HTTPURLResponse)?.statusCode))")
                    continue
                }
                
                try FileManager.default.moveItem(at: downloadURL, to: destinationURL)
            }

            await MainActor.run {
                progressHandler(0.9, "正在安装组件...")
            }
            
            let targetDirectory = "/Library/Application Support/Adobe/Adobe Desktop Common"

            if !FileManager.default.fileExists(atPath: targetDirectory) {
                let baseCommands = [
                    "mkdir -p '\(targetDirectory)'",
                    "chmod 755 '\(targetDirectory)'"
                ]

                for command in baseCommands {
                    let result = await withCheckedContinuation { continuation in
                        PrivilegedHelperManager.shared.executeCommand(command) { result in
                            continuation.resume(returning: result)
                        }
                    }
                    
                    if result.starts(with: "Error:") {
                        try? FileManager.default.removeItem(at: tempDirectory)
                        throw NetworkError.installError("创建目录失败: \(result)")
                    }
                }
            }

            for package in packagesToDownload {
                let packageDir = "\(targetDirectory)/\(package.name)"
                let packageCommands = [
                    "mkdir -p '\(packageDir)'",
                    "unzip -o '\(tempDirectory.path)/\(package.name).zip' -d '\(packageDir)/'",
                    "chmod -R 755 '\(packageDir)'",
                    "chown -R root:wheel '\(packageDir)'"
                ]
                
                for command in packageCommands {
                    let result = await withCheckedContinuation { continuation in
                        PrivilegedHelperManager.shared.executeCommand(command) { result in
                            continuation.resume(returning: result)
                        }
                    }
                    
                    if result.starts(with: "Error:") {
                        try? FileManager.default.removeItem(at: tempDirectory)
                        throw NetworkError.installError("安装 \(package.name) 失败: \(result)")
                    }
                }
            }

            try await withCheckedThrowingContinuation { continuation in
                ModifySetup.backupAndModifySetupFile { success, message in
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: NetworkError.installError(message))
                    }
                }
            }

            ModifySetup.clearVersionCache()

            try? FileManager.default.removeItem(at: tempDirectory)
            
            await MainActor.run {
                progressHandler(1.0, "安装完成")
            }
        } catch {
            print("发生错误: \(error.localizedDescription)")
            throw error
        }
    }

    private func handleDownloadError(_ error: Error, task: URLSessionTask) -> Error {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorCancelled:
            return NetworkError.cancelled
        case NSURLErrorTimedOut:
            return NetworkError.timeout
        case NSURLErrorNotConnectedToInternet:
            return NetworkError.noConnection
        case NSURLErrorCannotWriteToFile:
            if let expectedSize = task.response?.expectedContentLength {
                let fileManager = FileManager.default
                if let availableSpace = try? fileManager.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? Int64 {
                    return NetworkError.insufficientStorage(expectedSize, availableSpace)
                }
            }
            return NetworkError.downloadError("存储空间不足", error)
        default:
            return NetworkError.downloadError("下载失败: \(error.localizedDescription)", error)
        }
    }

    private func moveDownloadedFile(from location: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let destinationDirectory = destination.deletingLastPathComponent()
        
        do {
            if !fileManager.fileExists(atPath: destinationDirectory.path) {
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            }
            
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            
            try fileManager.moveItem(at: location, to: destination)
        } catch {
            switch (error as NSError).code {
            case NSFileWriteNoPermissionError:
                throw NetworkError.filePermissionDenied(destination.path)
            case NSFileWriteOutOfSpaceError:
                throw NetworkError.insufficientStorage(
                    try fileManager.attributesOfItem(atPath: location.path)[.size] as? Int64 ?? 0,
                    try fileManager.attributesOfFileSystem(forPath: NSHomeDirectory())[.systemFreeSize] as? Int64 ?? 0
                )
            default:
                throw NetworkError.fileSystemError("移动文件失败", error)
            }
        }
    }

    private func createDownloadTask(url: URL?, resumeData: Data?, session: URLSession) throws -> URLSessionDownloadTask {
        if let resumeData = resumeData {
            return session.downloadTask(withResumeData: resumeData)
        } else if let url = url {
            var request = URLRequest(url: url)
            NetworkConstants.downloadHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            return session.downloadTask(with: request)
        } else {
            throw NetworkError.invalidData("Neither URL nor resume data provided")
        }
    }
}
