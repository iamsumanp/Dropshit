import Foundation
import Combine

/// Queues OCR tasks (Make Searchable / Extract Text) and runs them
/// sequentially. Mirrors the shape of `ConversionService`.
@MainActor
final class OCRService: ObservableObject {
    /// 0...1 progress per source ShelfItem.id while a task is in flight.
    @Published private(set) var progress: [UUID: Double] = [:]

    /// Fires when a Make Searchable task succeeds. The URL is the new
    /// sibling PDF; the UUID is the shelf to receive it.
    let completedSearchable = PassthroughSubject<(URL, UUID), Never>()

    /// Fires when an Extract Text task succeeds. The String is the
    /// recognized text; the UUID is the shelf to receive it.
    let completedExtracted = PassthroughSubject<(String, UUID), Never>()

    /// Fires on terminal failure or cancellation. (`.cancelled` is
    /// silenced by the AppDelegate subscriber.)
    let failed = PassthroughSubject<OCRError, Never>()

    private enum Job {
        case makeSearchable(source: URL)
        case extractTextPDF(source: URL)
        case extractTextImage(source: URL)

        // Helper enum to share success-payload shape between branches.
        enum Outcome {
            case searchable(url: URL)
            case text(String)
        }
    }

    private struct QueuedTask {
        let itemID: UUID
        let shelfID: UUID
        let job: Job
    }

    private var queue: [QueuedTask] = []
    private var inFlight: QueuedTask?
    private var inFlightTask: Task<Void, Never>?

    // MARK: - Public API

    func enqueueMakeSearchable(sourceItemID: UUID, shelfID: UUID, source: URL) {
        queue.append(QueuedTask(
            itemID: sourceItemID, shelfID: shelfID,
            job: .makeSearchable(source: source)
        ))
        progress[sourceItemID] = 0
        runNextIfIdle()
    }

    func enqueueExtractText(
        sourceItemID: UUID,
        shelfID: UUID,
        source: URL,
        isPDF: Bool
    ) {
        queue.append(QueuedTask(
            itemID: sourceItemID, shelfID: shelfID,
            job: isPDF ? .extractTextPDF(source: source) : .extractTextImage(source: source)
        ))
        progress[sourceItemID] = 0
        runNextIfIdle()
    }

    func cancel(itemID: UUID) {
        queue.removeAll { $0.itemID == itemID }
        if inFlight?.itemID == itemID {
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

    private func run(_ task: QueuedTask) async {
        let progressClosure: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.progress[task.itemID] = p
            }
        }

        let result: Result<Job.Outcome, OCRError>
        do {
            switch task.job {
            case .makeSearchable(let source):
                let url = try await PDFOCR.makeSearchable(
                    source: source, progress: progressClosure
                )
                result = .success(.searchable(url: url))
            case .extractTextPDF(let source):
                let text = try await PDFOCR.extractText(
                    source: source, progress: progressClosure
                )
                result = .success(.text(text))
            case .extractTextImage(let source):
                progressClosure(0.5)
                let text = try await ImageOCR.extractText(source: source)
                progressClosure(1.0)
                result = .success(.text(text))
            }
        } catch is CancellationError {
            result = .failure(.cancelled)
        } catch let e as OCRError {
            result = .failure(e)
        } catch {
            result = .failure(.recognitionFailed(reason: error.localizedDescription))
        }
        finish(task: task, result: result)
    }

    private func finish(task: QueuedTask, result: Result<Job.Outcome, OCRError>) {
        progress.removeValue(forKey: task.itemID)
        inFlight = nil
        inFlightTask = nil

        switch result {
        case .success(.searchable(let url)):
            completedSearchable.send((url, task.shelfID))
        case .success(.text(let text)):
            completedExtracted.send((text, task.shelfID))
        case .failure(let err):
            failed.send(err)
        }
        runNextIfIdle()
    }
}
