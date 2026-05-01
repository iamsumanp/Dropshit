import Foundation
import Combine

/// Queues PDF flatten/save tasks. One in flight at a time. Mirrors
/// `OCRService` / `ConversionService`.
@MainActor
final class PDFEditService: ObservableObject {
    @Published private(set) var progress: [UUID: Double] = [:]

    let completed = PassthroughSubject<(URL, UUID /* shelfID */), Never>()
    let failed = PassthroughSubject<PDFEditError, Never>()

    private struct QueuedSave {
        let saveID: UUID
        let shelfID: UUID
        let source: URL
        let edits: PDFEditDocument
    }

    private var queue: [QueuedSave] = []
    private var inFlight: QueuedSave?
    private var inFlightTask: Task<Void, Never>?

    func enqueueSave(
        saveID: UUID = UUID(),
        shelfID: UUID,
        source: URL,
        edits: PDFEditDocument
    ) {
        let task = QueuedSave(
            saveID: saveID, shelfID: shelfID, source: source, edits: edits
        )
        queue.append(task)
        progress[saveID] = 0
        runNextIfIdle()
    }

    func cancel(itemID: UUID) {
        queue.removeAll { $0.saveID == itemID }
        if inFlight?.saveID == itemID {
            inFlightTask?.cancel()
        }
        progress.removeValue(forKey: itemID)
    }

    func cancelAll() {
        queue.removeAll()
        inFlightTask?.cancel()
        progress.removeAll()
    }

    // MARK: - Internals

    private func runNextIfIdle() {
        guard inFlight == nil, !queue.isEmpty else { return }
        let task = queue.removeFirst()
        inFlight = task
        inFlightTask = Task { [weak self] in
            await self?.run(task)
        }
    }

    private func run(_ task: QueuedSave) async {
        let progressClosure: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.progress[task.saveID] = p
            }
        }

        let result: Result<URL, PDFEditError>
        do {
            let url = try await PDFEditFlatten.flatten(
                source: task.source,
                edits: task.edits,
                progress: progressClosure
            )
            result = .success(url)
        } catch is CancellationError {
            result = .failure(.cancelled)
        } catch let e as PDFEditError {
            result = .failure(e)
        } catch {
            result = .failure(.flattenFailed(reason: error.localizedDescription))
        }
        finish(task: task, result: result)
    }

    private func finish(task: QueuedSave, result: Result<URL, PDFEditError>) {
        progress.removeValue(forKey: task.saveID)
        inFlight = nil
        inFlightTask = nil

        switch result {
        case .success(let url):
            completed.send((url, task.shelfID))
        case .failure(let err):
            failed.send(err)
        }
        runNextIfIdle()
    }
}
