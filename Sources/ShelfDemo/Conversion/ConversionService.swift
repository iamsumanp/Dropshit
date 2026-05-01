import Foundation
import Combine

/// Queues conversion tasks and runs them sequentially. UI observes
/// `progress` (per source-item id) and `failures` (a passthrough subject).
///
/// Note: this is a `@MainActor ObservableObject` rather than an actor so
/// SwiftUI views can `@ObservedObject` it. Heavy work runs on a background
/// queue inside the per-task implementation.
@MainActor
final class ConversionService: ObservableObject {
    /// 0...1 progress per source ShelfItem.id while a task is in flight.
    /// Absent → idle. 1.0 is set briefly on completion before the entry is
    /// removed.
    @Published private(set) var progress: [UUID: Double] = [:]

    /// Fires when a converted file is ready, with the shelf to receive it.
    let completed = PassthroughSubject<(URL, UUID /* shelfID */), Never>()

    /// Fires when a task fails (already cancelled tasks emit `.cancelled`).
    let failed = PassthroughSubject<ConversionError, Never>()

    private struct QueuedTask {
        let itemID: UUID
        let shelfID: UUID
        let source: URL
        let target: ConversionTarget
    }

    private var queue: [QueuedTask] = []
    private var inFlight: QueuedTask?
    private var inFlightVideoHandle: VideoConverter.Handle?
    private let workQueue = DispatchQueue(
        label: "shelfdemo.conversion.work", qos: .userInitiated
    )

    func enqueue(
        sourceItemID: UUID,
        shelfID: UUID,
        source: URL,
        target: ConversionTarget
    ) {
        queue.append(QueuedTask(
            itemID: sourceItemID, shelfID: shelfID,
            source: source, target: target
        ))
        progress[sourceItemID] = 0
        runNextIfIdle()
    }

    /// Cancels the in-flight task for `itemID` (if any) and removes any
    /// queued tasks for the same item. No-op otherwise.
    func cancel(itemID: UUID) {
        queue.removeAll { $0.itemID == itemID }
        if inFlight?.itemID == itemID {
            inFlightVideoHandle?.cancel()
            // Image tasks are synchronous and cannot be interrupted; they
            // complete and just emit a noop result.
        }
        progress.removeValue(forKey: itemID)
    }

    /// Cancels everything. Used at app quit.
    func cancelAll() {
        queue.removeAll()
        inFlightVideoHandle?.cancel()
        progress.removeAll()
    }

    // MARK: - Internals

    private func runNextIfIdle() {
        guard inFlight == nil, !queue.isEmpty else { return }
        let task = queue.removeFirst()
        inFlight = task

        if task.target == .mp4 {
            inFlightVideoHandle = VideoConverter.convertToMP4(
                source: task.source,
                progress: { [weak self] p in
                    guard let self else { return }
                    self.progress[task.itemID] = p
                },
                completion: { [weak self] result in
                    self?.finish(task: task, result: result)
                }
            )
            if inFlightVideoHandle == nil {
                // VideoConverter already invoked completion synchronously.
                // Nothing else to do.
            }
        } else {
            workQueue.async { [weak self] in
                let result: Result<URL, ConversionError>
                do {
                    let url = try ImageConverter.convert(
                        source: task.source, target: task.target
                    )
                    result = .success(url)
                } catch let e as ConversionError {
                    result = .failure(e)
                } catch {
                    result = .failure(.encodingFailed(
                        reason: error.localizedDescription
                    ))
                }
                Task { @MainActor [weak self] in
                    self?.finish(task: task, result: result)
                }
            }
        }
    }

    private func finish(
        task: QueuedTask,
        result: Result<URL, ConversionError>
    ) {
        progress.removeValue(forKey: task.itemID)
        inFlight = nil
        inFlightVideoHandle = nil

        switch result {
        case .success(let url):
            completed.send((url, task.shelfID))
        case .failure(let err):
            failed.send(err)
        }
        runNextIfIdle()
    }
}
