import Foundation

// Turning a found edge sequence into a route: its line, length, time and turn-by-turn steps.

extension RouteEngine {
    /// The part of one directed edge a route drives: fractions of its length in its own
    /// direction, and where it begins along the route (metres).
    struct Leg {
        var edge: Int32
        var from: Double, to: Double
        var along: Double
    }

    /// The route along `edges`, starting `startFraction` of the way along the first and ending
    /// `endFraction` of the way along the last (each in that edge's own direction).
    func assemble(_ edges: [Int32], startFraction: Double, endFraction: Double) -> RoutePath {
        var points: [LonLat] = []
        var distance = 0.0, duration = 0.0
        var legs: [Leg] = []
        legs.reserveCapacity(edges.count)
        for (i, de) in edges.enumerated() {
            let a = i == 0 ? startFraction : 0, b = i == edges.count - 1 ? endFraction : 1
            let leg = Leg(edge: de, from: min(a, b), to: max(a, b), along: distance)
            legs.append(leg)
            let line = polyline(of: leg)
            points.append(contentsOf: points.isEmpty ? line[...] : line.dropFirst())
            distance += length(leg)
            duration += time(leg)
            // Junctions and turns take time too (the same costs the search used).
            if i > 0, let turn = turnCost(edges[i - 1], de, at: graph.head(edges[i - 1])) { duration += Double(turn) }
        }
        let end = points.last ?? graph.position(graph.head(edges[edges.count - 1]))
        return RoutePath(edges: edges, points: points, distance: distance, duration: duration,
                         steps: steps(legs, end: end, total: distance))
    }

    private func length(_ leg: Leg) -> Double { Double(graph.length[Int(leg.edge >> 1)]) * (leg.to - leg.from) }

    /// Seconds to drive a leg (no turn costs).
    private func time(_ leg: Leg) -> Double {
        let metres = length(leg), kmh = Double(graph.speed(leg.edge))
        return metres > 0 && kmh > 0 ? metres / (kmh / 3.6) : 0
    }

    // MARK: Geometry

    /// The leg's line: the whole edge, or the stretch between its two fractions.
    private func polyline(of leg: Leg) -> [LonLat] {
        let whole = graph.polyline(directed: leg.edge)
        if leg.from <= 0 && leg.to >= 1 { return whole }
        return Self.cut(whole, from: leg.from, to: leg.to)
    }

    /// `line` between two fractions of its length.
    static func cut(_ line: [LonLat], from f0: Double, to f1: Double) -> [LonLat] {
        guard line.count >= 2 else { return line }
        let flat = CameraExposure.Flat(lat: line[0].lat)
        let xy = line.map(flat.xy)
        // Distance from the start to each point.
        var reach = [0.0]
        reach.reserveCapacity(xy.count)
        for i in 1..<xy.count { let d = xy[i] - xy[i - 1]; reach.append(reach[i - 1] + (d * d).sum().squareRoot()) }
        let d0 = reach[reach.count - 1] * f0, d1 = reach[reach.count - 1] * f1
        func point(at d: Double) -> LonLat {
            var i = 1
            while i < reach.count - 1 && reach[i] < d { i += 1 }
            let segment = reach[i] - reach[i - 1]
            let t = segment > 0 ? (d - reach[i - 1]) / segment : 0
            let q = xy[i - 1] + (xy[i] - xy[i - 1]) * min(1, max(0, t))
            return LonLat(lon: q.x / flat.kx, lat: q.y / flat.ky)
        }
        var out = [point(at: d0)]
        for i in 1..<(reach.count - 1) where reach[i] > d0 && reach[i] < d1 { out.append(line[i]) }
        out.append(point(at: d1))
        return out
    }

    /// Where a leg begins.
    private func startPoint(_ leg: Leg) -> LonLat {
        if leg.from <= 0 { return graph.position(graph.tail(leg.edge)) }
        return Self.cut(graph.polyline(directed: leg.edge), from: leg.from, to: leg.from)[0]
    }

    // MARK: Steps

    private func roadName(_ de: Int32) -> String? { graph.roadName(Int(de >> 1)) }
    private func roadClass(_ de: Int32) -> RoadClass { RoadClass(rawValue: graph.roadClass[Int(de >> 1)]) ?? .road }
    private func isRoundabout(_ de: Int32) -> Bool { graph.flags[Int(de >> 1)] & RoadGraph.roundaboutFlag != 0 }

    /// Ways out of `v` other than back along `arrival`.
    private func choices(at v: Int32, arrivingOn arrival: Int32) -> Int {
        var n = 0
        for k in Int(graph.adjStart[Int(v)])..<Int(graph.adjStart[Int(v) + 1]) where graph.adj[k] >> 1 != arrival >> 1 { n += 1 }
        return n
    }

    /// One step per manoeuvre: leaving, each turn worth telling, arriving. Every leg's length and
    /// time go to the step it is driven under.
    func steps(_ legs: [Leg], end: LonLat, total: Double) -> [RouteStep] {
        guard let first = legs.first else { return [] }
        var out = [departure(first)]
        // Whether the roundabout being driven has had its "take the nth exit" step.
        var roundaboutAnnounced = false
        for i in legs.indices {
            out[out.count - 1].distance += length(legs[i])
            out[out.count - 1].duration += time(legs[i])
            guard i + 1 < legs.count else { break }
            let here = legs[i], next = legs[i + 1]
            if isRoundabout(next.edge) {
                if !isRoundabout(here.edge) {
                    out.append(roundaboutStep(entering: i + 1, legs))
                    roundaboutAnnounced = true
                }
                continue        // going round: nothing to say until the exit
            }
            if isRoundabout(here.edge), roundaboutAnnounced {
                // Leaving by the exit already announced (this used to add a second, redundant
                // "bear right onto …" step).
                roundaboutAnnounced = false
                continue
            }
            if let step = manoeuvre(from: here, to: next) { out.append(step) }
        }
        out.append(RouteStep(kind: .arrive, text: "Arrive at your destination", road: nil, distance: 0, duration: 0, location: end, along: total))
        return out
    }

    private func departure(_ first: Leg) -> RouteStep {
        let compass = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        let heading = compass[Int(((leaving(first.edge) + 22.5) / 45).rounded(.down)) % 8]
        let road = roadName(first.edge)
        return RouteStep(kind: .depart, text: road.map { "Head \(heading) on \($0)" } ?? "Head \(heading)",
                         road: road, distance: 0, duration: 0, location: startPoint(first), along: 0)
    }

    /// "At the roundabout, take the nth exit": counts the exits passed from the leg that enters
    /// the roundabout up to and including the one the route leaves by.
    private func roundaboutStep(entering index: Int, _ legs: [Leg]) -> RouteStep {
        var j = index, exits = 0
        while j < legs.count && isRoundabout(legs[j].edge) {
            let v = graph.head(legs[j].edge)
            let hasExit = (Int(graph.adjStart[Int(v)])..<Int(graph.adjStart[Int(v) + 1])).contains { !isRoundabout(graph.adj[$0]) }
            if hasExit { exits += 1 }
            j += 1
        }
        let exitRoad = j < legs.count ? roadName(legs[j].edge) : nil
        let exit = max(1, exits)
        return RouteStep(kind: .roundabout(exit: exit),
                         text: "At the roundabout, take the \(Self.ordinal(exit)) exit" + (exitRoad.map { " onto \($0)" } ?? ""),
                         road: exitRoad, distance: 0, duration: 0, location: startPoint(legs[index]), along: legs[index].along)
    }

    /// The step for going from one leg to the next, or nil when there is nothing to tell (the
    /// same road carrying on, or a bend with no other way to go).
    private func manoeuvre(from here: Leg, to next: Leg) -> RouteStep? {
        let t = turn(here.edge, next.edge)
        let sharpness = abs(t)
        let name = roadName(next.edge)
        let renamed = roadName(here.edge) != name && name != nil
        let options = choices(at: graph.head(here.edge), arrivingOn: here.edge)
        let classHere = roadClass(here.edge), classNext = roadClass(next.edge)
        let kind: RouteStep.Kind
        if classNext.isLink && !classHere.isLink {
            kind = .ramp(left: t < 0)
        } else if classHere.isLink && classNext.isHighway {
            kind = .merge
        } else if renamed || (options > 1 && sharpness >= 35) {
            // A new road, or a real choice at a junction.
            if sharpness < 20 {
                kind = classHere.isHighway && options > 1 && sharpness >= 8 ? (t < 0 ? .keepLeft : .keepRight) : .straight
            } else if sharpness < 60 {
                kind = t < 0 ? .slightLeft : .slightRight
            } else if sharpness < 135 {
                kind = t < 0 ? .left : .right
            } else if sharpness < 170 {
                kind = t < 0 ? .sharpLeft : .sharpRight
            } else {
                kind = .uTurn
            }
        } else {
            return nil
        }
        return RouteStep(kind: kind, text: Self.phrase(kind, name), road: name, distance: 0, duration: 0,
                         location: startPoint(next), along: next.along)
    }

    static func phrase(_ k: RouteStep.Kind, _ road: String?) -> String {
        let onto = road.map { " onto \($0)" } ?? ""
        switch k {
        case .straight: return road.map { "Continue onto \($0)" } ?? "Continue straight"
        case .slightLeft: return "Bear left" + onto
        case .slightRight: return "Bear right" + onto
        case .left: return "Turn left" + onto
        case .right: return "Turn right" + onto
        case .sharpLeft: return "Turn sharp left" + onto
        case .sharpRight: return "Turn sharp right" + onto
        case .uTurn: return "Make a U-turn" + onto
        case .ramp(let left): return "Take the ramp on the \(left ? "left" : "right")" + onto
        case .merge: return "Merge" + onto
        case .keepLeft: return "Keep left" + onto
        case .keepRight: return "Keep right" + onto
        case .depart, .arrive, .roundabout: return ""
        }
    }

    static func ordinal(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "\(n)th" }
        switch n % 10 { case 1: return "\(n)st"; case 2: return "\(n)nd"; case 3: return "\(n)rd"; default: return "\(n)th" }
    }
}
