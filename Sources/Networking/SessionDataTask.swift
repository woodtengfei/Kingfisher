//
//  SessionDataTask.swift
//  Kingfisher
//
//  Created by Wei Wang on 2018/11/1.
//
//  Copyright (c) 2018年 Wei Wang <onevcat@gmail.com>
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

import Foundation

public class SessionDataTask {

    public typealias CancelToken = Int

    struct TaskCallback {
        let onProgress: Delegate<(Int64, Int64), Void>?
        let onCompleted: Delegate<Result<ImageDownloadResult>, Void>?
        let options: KingfisherOptionsInfo
    }

    public private(set) var mutableData: Data
    public let task: URLSessionDataTask

    private var callbacksStore = [CancelToken: TaskCallback]()

    var callbacks: Dictionary<SessionDataTask.CancelToken, SessionDataTask.TaskCallback>.Values {
        return callbacksStore.values
    }

    var currentToken = 0

    private let lock = NSLock()

    let onTaskDone = Delegate<(Result<(Data, URLResponse?)>, [TaskCallback]), Void>()
    let onTaskCancelled = Delegate<(CancelToken, TaskCallback), Void>()

    var started = false
    var containsCallbacks: Bool {
        // We should be able to use `task.state != .running` to check it.
        // However, in some rare cases, cancelling the task does not change
        // task state to `.cancelling`, but still in `.running`. So we need
        // to check callbacks count to for sure that it is safe to remove the
        // task in delegate.
        return !callbacks.isEmpty
    }

    init(task: URLSessionDataTask) {
        self.task = task
        mutableData = Data()
    }

    func addCallback(_ callback: TaskCallback) -> CancelToken {
        lock.lock()
        defer { lock.unlock() }
        callbacksStore[currentToken] = callback
        defer { currentToken += 1 }
        return currentToken
    }

    func removeCallback(_ token: CancelToken) -> TaskCallback? {
        lock.lock()
        defer { lock.unlock() }
        if let callback = callbacksStore[token] {
            callbacksStore[token] = nil
            return callback
        }
        return nil
    }

    func resume() {
        started = true
        task.resume()
    }

    func cancel(token: CancelToken) {
        let result = removeCallback(token)
        if let callback = result {

            if callbacksStore.count == 0 {
                task.cancel()
            }

            onTaskCancelled.call((token, callback))
        }
    }

    func forceCancel() {
        for token in callbacksStore.keys {
            cancel(token: token)
        }
    }

    func didReceiveData(_ data: Data) {
        mutableData.append(data)
    }
}
