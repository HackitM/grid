import GridCore
import Observation

/// The cameras in view: how many (the readout's "ALPR n IN VIEW") and, while the LIST section is
/// open, the ones nearest the map centre. Both follow the camera during gestures, and a query
/// over a large index (a country has well over 100,000 cameras) takes milliseconds, so the work
/// runs off the main thread, one query at a time, always for the latest view.
@Observable
@MainActor
final class CamerasInView {
    struct Row: Identifiable, Sendable {
        /// The camera's index in `ALPRStore.index`.
        let index: Int
        let camera: ALPRCamera
        /// Metres from the map centre.
        let distance: Double
        var id: Int { index }
    }

    nonisolated static let listLimit = 60

    /// nil until the first count is in (and when there is nothing to count).
    private(set) var count: Int?
    /// Nearest the map centre first; kept up to date only while `listOpen`.
    private(set) var nearest: [Row] = []
    /// The LIST section is showing. The model starts a recount when this changes.
    var listOpen = false

    private struct Request: Sendable {
        var index: CameraIndex
        var box: BBox
        var centre: LonLat
        var wantsList: Bool
    }

    /// What a request was made for; an identical one is not repeated.
    private struct Key: Equatable {
        var revision: Int
        var box: BBox
        /// Only matters for the list (distances are from the centre).
        var centre: LonLat?
    }

    @ObservationIgnored private var lastKey: Key?
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var running = false
    /// Bumped by `reset()`: results of queries started before it are dropped.
    @ObservationIgnored private var epoch = 0

    /// Asks for the cameras of `index` inside `box`. Returns at once; `count` (and `nearest`)
    /// change when the query has run. Calls made while a query runs replace each other, so at
    /// most one is waiting.
    func update(index: CameraIndex, revision: Int, box: BBox, centre: LonLat) {
        let key = Key(revision: revision, box: box, centre: listOpen ? centre : nil)
        guard key != lastKey else { return }
        lastKey = key
        pending = Request(index: index, box: box, centre: centre, wantsList: listOpen)
        guard !running else { return }
        running = true
        Task {
            while let request = pending {
                pending = nil
                let startedIn = epoch
                let result = await Task.detached(priority: .utility) { Self.query(request) }.value
                guard startedIn == epoch else { continue }
                if count != result.count { count = result.count }
                if request.wantsList { nearest = result.nearest }
            }
            running = false
        }
    }

    /// Nothing to count (the camera layer is off, or no cameras are downloaded).
    func reset() {
        epoch &+= 1
        pending = nil
        lastKey = nil
        if count != nil { count = nil }
        if !nearest.isEmpty { nearest = [] }
    }

    private nonisolated static func query(_ request: Request) -> (count: Int, nearest: [Row]) {
        let hits = request.index.query(request.box)
        guard request.wantsList else { return (hits.count, []) }
        let rows = hits.map { i -> Row in
            let camera = request.index.cameras[i]
            return Row(index: i, camera: camera, distance: MapModel.distance(request.centre, camera.coordinate))
        }
        return (hits.count, Array(rows.sorted { $0.distance < $1.distance }.prefix(listLimit)))
    }
}
