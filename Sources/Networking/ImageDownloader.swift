//
//  ImageDownloader.swift
//  Kingfisher
//
//  Created by Wei Wang on 15/4/6.
//
//  Copyright (c) 2018 Wei Wang <onevcat@gmail.com>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Represents a success result of an image downloading progess.
public struct ImageDownloadResult {

    /// The downloaded image.
    public let image: Image

    /// Original URL of the image request.
    public let url: URL

    /// The raw data received from downloader.
    public let originalData: Data
}

/// Represents a task of an image downloading process.
public struct DownloadTask {

    // Multiple `DownloadTask`s could refer to a same `sessionTask`. This is an optimization in Kingfisher to
    // prevent multiple downloading task for the same URL resource at the same time.
    let sessionTask: SessionDataTask

    // Callbacks for this `DownloadTask` needs to be identified with the `CancelToken`.
    let cancelToken: SessionDataTask.CancelToken

    /// Cancel this task if it is running. It will do nothing if this task is not running.
    ///
    /// - Note:
    /// In Kingfisher, there is an optimization to prevent starting another download task if the target URL is being
    /// downloading. However, even when internally no new session task created, a `DownloadTask` will be still created
    /// and returned when you call related methods, but it will share the session downloading task with a previous task.
    /// In this case, if multiple `DownloadTask`s share a single session download task, cancelling a `DownloadTask`
    /// does not affect other `DownloadTask`s.
    ///
    /// If you need to cancel all `DownloadTask`s of a url, use `ImageDownloader.cancel(url:)`. If you need to cancel
    /// all downloading tasks of an `ImageDownloader`, use `ImageDownloader.cancelAll()`.
    public func cancel() {
        sessionTask.cancel(token: cancelToken)
    }
}

/// Represents a downloading manager for requesting the image with a URL from server.
open class ImageDownloader {

    /// The default downloader.
    public static let `default` = ImageDownloader(name: "default")

    // MARK: - Public property
    /// The duration before the downloading is timeout. Default is 15 seconds.
    open var downloadTimeout: TimeInterval = 15.0
    
    /// A set of trusted hosts when receiving server trust challenges. A challenge with host name contained in this
    /// set will be ignored. You can use this set to specify the self-signed site. It only will be used if you don't
    /// specify the `authenticationChallengeResponder`.
    ///
    /// If `authenticationChallengeResponder` is set, this property will be ignored and the implementation of
    /// `authenticationChallengeResponder` will be used instead.
    open var trustedHosts: Set<String>?
    
    /// Use this to set supply a configuration for the downloader. By default,
    /// NSURLSessionConfiguration.ephemeralSessionConfiguration() will be used.
    ///
    /// You could change the configuration before a downloading task starts.
    /// A configuration without persistent storage for caches is requested for downloader working correctly.
    open var sessionConfiguration = URLSessionConfiguration.ephemeral {
        didSet {
            session.invalidateAndCancel()
            session = URLSession(configuration: sessionConfiguration, delegate: sessionHandler, delegateQueue: nil)
        }
    }
    
    /// Whether the download requests should use pipline or not. Default is false.
    open var requestsUsePipelining = false

    /// Delegate of this `ImageDownloader` object. See `ImageDownloaderDelegate` protocol for more.
    open weak var delegate: ImageDownloaderDelegate?
    
    /// A responder for authentication challenge. 
    /// Downloader will forward the received authentication challenge for the downloading session to this responder.
    open weak var authenticationChallengeResponder: AuthenticationChallengeResponsable?

    private let name: String
    private let sessionHandler: SessionDelegate
    private var session: URLSession

    /// Creates a downloader with name.
    ///
    /// - Parameter name: The name for the downloader. It should not be empty.
    public init(name: String) {
        if name.isEmpty {
            fatalError("[Kingfisher] You should specify a name for the downloader. "
                + "A downloader with empty name is not permitted.")
        }

        self.name = name
        sessionHandler = SessionDelegate()
        session = URLSession(configuration: sessionConfiguration, delegate: sessionHandler, delegateQueue: nil)
        authenticationChallengeResponder = self
        setupSessionHandler()
    }

    deinit { session.invalidateAndCancel() }

    private func setupSessionHandler() {
        sessionHandler.onReceiveSessionChallenge.delegate(on: self) { (self, invoke) in
            self.authenticationChallengeResponder?.downloader(self, didReceive: invoke.1, completionHandler: invoke.2)
        }
        sessionHandler.onReceiveSessionTaskChallenge.delegate(on: self) { (self, invoke) in
            self.authenticationChallengeResponder?.downloader(
                self, task: invoke.1, didReceive: invoke.2, completionHandler: invoke.3)
        }
        sessionHandler.onValidStatusCode.delegate(on: self) { (self, code) in
            return (self.delegate ?? self).isValidStatusCode(code, for: self)
        }
        sessionHandler.onDownloadingFinished.delegate(on: self) { (self, value) in
            let (url, result) = value
            self.delegate?.imageDownloader(
                self, didFinishDownloadingImageForURL: url, with: result.value, error: result.error)
        }
        sessionHandler.onDidDownloadData.delegate(on: self) { (self, task) in
            guard let url = task.task.originalRequest?.url else {
                return task.mutableData
            }
            guard let delegate = self.delegate else {
                return task.mutableData
            }
            return delegate.imageDownloader(self, didDownload: task.mutableData, for: url)
        }
    }

    /// Downloads an image with a URL and option.
    ///
    /// - Parameters:
    ///   - url: Target URL.
    ///   - options: The options could control download behavior. See `KingfisherOptionsInfo`.
    ///   - progressBlock: Called when the download progress updated. This block will be always be called in main queue.
    ///   - completionHandler: Called when the download progress finishes. This block will be called in the queue
    ///                        defined in `.callbackQueue` in `options` parameter.
    /// - Returns: A downloading task. You could call `cancel` on it to stop the download task.
    @discardableResult
    open func downloadImage(with url: URL,
                            options: KingfisherOptionsInfo? = nil,
                            progressBlock: DownloadProgressBlock? = nil,
                            completionHandler: ((Result<ImageDownloadResult>) -> Void)? = nil) -> DownloadTask?
    {
        // Creates default request.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: downloadTimeout)
        request.httpShouldUsePipelining = requestsUsePipelining

        let options = options ?? .empty

        // Modifies request before sending.
        guard let r = options.modifier.modified(for: request) else {
            options.callbackQueue.execute {
                completionHandler?(.failure(KingfisherError.requestError(reason: .emptyRequest)))
            }
            return nil
        }
        request = r
        
        // There is a possibility that request modifier changed the url to `nil` or empty.
        // In this case, throw an error.
        guard let url = request.url, !url.absoluteString.isEmpty else {
            options.callbackQueue.execute {
                completionHandler?(.failure(KingfisherError.requestError(reason: .invalidURL(request: request))))
            }
            return nil
        }

        // Wraps `progressBlock` and `completionHandler` to `onProgress` and `onCompleted` respectively.
        let onProgress = progressBlock.map {
            block -> Delegate<(Int64, Int64), Void> in
            let delegate = Delegate<(Int64, Int64), Void>()
            delegate.delegate(on: self) { (_, progress) in
                let (downloaded, total) = progress
                block(downloaded, total)
            }
            return delegate
        }

        let onCompleted = completionHandler.map {
            block -> Delegate<Result<ImageDownloadResult>, Void> in
            let delegate =  Delegate<Result<ImageDownloadResult>, Void>()
            delegate.delegate(on: self) { (_, result) in
                block(result)
            }
            return delegate
        }

        // SessionDataTask.TaskCallback is a wrapper for `onProgress`, `onCompleted` and `options` (for processor info)
        let callback = SessionDataTask.TaskCallback(
            onProgress: onProgress, onCompleted: onCompleted, options: options)

        // Ready to start download. Add it to session task manager (`sessionHandler`)
        let dataTask = session.dataTask(with: request)
        dataTask.priority = options.downloadPriority

        let downloadTask = sessionHandler.add(dataTask, url: url, callback: callback)

        let sessionTask = downloadTask.sessionTask
        sessionTask.onTaskDone.delegate(on: self) { (self, done) in
            // Underlying downloading finishes.
            // result: Result<(Data, URLResponse?)>, callbacks: [TaskCallback]
            let (result, callbacks) = done

            // Before processing the downloaded data.
            self.delegate?.imageDownloader(
                self,
                didFinishDownloadingImageForURL: url,
                with: result.value?.1,
                error: result.error)

            switch result {
            // Download finished. Now process the data to an image.
            case .success(let (data, response)):
                let prosessor = ImageDataProcessor(name: self.name, data: data, callbacks: callbacks)
                prosessor.onImageProcessed.delegate(on: self) { (self, result) in
                    // `onImageProcessed` will be called for `callbacks.count` times, with each
                    // `SessionDataTask.TaskCallback` as the input parameter.
                    // result: Result<Image>, callback: SessionDataTask.TaskCallback
                    let (result, callback) = result

                    if let image = result.value {
                        self.delegate?.imageDownloader(self, didDownload: image, for: url, with: response)
                    }

                    let imageResult = result.map { ImageDownloadResult(image: $0, url: url, originalData: data) }
                    let queue = callback.options.callbackQueue
                    queue.execute { callback.onCompleted?.call(imageResult) }
                }
                prosessor.process()

            case .failure(let error):
                callbacks.forEach { callback in
                    let queue = callback.options.callbackQueue
                    queue.execute { callback.onCompleted?.call(.failure(error)) }
                }
            }
        }

        // Start the session task if not started yet.
        if !sessionTask.started {
            delegate?.imageDownloader(self, willDownloadImageForURL: url, with: request)
            sessionTask.resume()
        }
        return downloadTask
    }
}

// MARK: - Download method
extension ImageDownloader {

    /// Cancel all downloading tasks for this `ImageDownloader`. It will trigger the completion handlers
    /// for all not-yet-finished downloading tasks.
    ///
    /// If you need to only cancel a certain task, call `cancel()` on the `DownloadTask`
    /// returned by the downloading methods. If you need to cancel all `DownloadTask`s of a certain url,
    /// use `ImageDownloader.cancel(url:)`.
    public func cancelAll() {
        sessionHandler.cancelAll()
    }

    /// Cancel all downloading tasks for a given URL. It will trigger the completion handlers for
    /// all not-yet-finished downloading tasks for the URL.
    ///
    /// - Parameter url: The URL which you want to cancel downloading.
    public func cancel(url: URL) {
        sessionHandler.cancel(url: url)
    }
}

// Use the default implementation from extension of `AuthenticationChallengeResponsable`.
extension ImageDownloader: AuthenticationChallengeResponsable {}

// Placeholder. For retrieving extension methods of ImageDownloaderDelegate
extension ImageDownloader: ImageDownloaderDelegate {}
