import CoreLocation
import Foundation
import MapKit

struct MarineRouteRequest {
    var origin: CLLocationCoordinate2D?
    var destination: CLLocationCoordinate2D
    var boatProfile: RouteBoatProfile?
}

struct RouteBoatProfile: Sendable {
    var boatName: String?
    var preferredCruisingSpeedKnots: Double?
    var estimatedFuelLitersPerHour: Double?
    var estimatedFuelLitersPerNauticalMile: Double?
    var fuelPricePerLiter: Decimal?
    var fuelRemainingLiters: Double?
    var currencyCode: String
}

enum RouteValidationStatus: Equatable, Sendable {
    case passedEstimatedWaterConnectivity
    case failed(String)

    var allowsPreview: Bool {
        if case .passedEstimatedWaterConnectivity = self { return true }
        return false
    }
}

enum MarineRoutingProviderKind: String, Sendable {
    case estimatedCoastalWater
    case licensedMarine
    case offlineMarine
}

enum RouteConstraintStatus: String, Sendable {
    case verified
    case notVerified
    case unavailable
    case notApplicable
}

struct RouteConstraintReport: Sendable, Equatable {
    var depth: RouteConstraintStatus
    var bridgeClearance: RouteConstraintStatus
    var restrictedAreas: RouteConstraintStatus
    var landAvoidance: RouteConstraintStatus

    static let estimated = RouteConstraintReport(
        depth: .unavailable,
        bridgeClearance: .unavailable,
        restrictedAreas: .unavailable,
        landAvoidance: .notVerified
    )
}

struct MarineRouteDiagnostics: Sendable {
    var provider: MarineRoutingProviderKind
    var origin: CLLocationCoordinate2D
    var destination: CLLocationCoordinate2D
    var snappedOrigin: CLLocationCoordinate2D
    var snappedDestination: CLLocationCoordinate2D
    var originSnapDistanceNauticalMiles: Double
    var destinationSnapDistanceNauticalMiles: Double
    var graphNodeCount: Int
    var graphEdgeCount: Int
    var startNodeID: String
    var endNodeID: String
    var pathNodeCount: Int
    var finalCoordinateCount: Int
    var distanceNauticalMiles: Double
    var calculationMilliseconds: Double
    var landIntersectionResult: String
}

struct MarineRouteSummary {
    var destinationName: String
    var distanceNauticalMiles: Double?
    var estimatedDurationSeconds: TimeInterval?
    var estimatedFuelLiters: Double?
    var estimatedFuelCost: Decimal?
    var cruisingSpeedKnots: Double?
    var boatName: String?
    var remainingRangeNauticalMiles: Double?
    var remainingHours: Double?
    var costPerNauticalMile: Decimal?
    var estimatedFuelRemainingAfterTripLiters: Double?
    var currencyCode: String
    var coordinates: [CLLocationCoordinate2D]
    var routeBounds: MKCoordinateRegion
    var routingSource: String
    var providerKind: MarineRoutingProviderKind
    var validationStatus: RouteValidationStatus
    var constraintReport: RouteConstraintReport
    var snappedOrigin: CLLocationCoordinate2D
    var snappedDestination: CLLocationCoordinate2D
    var diagnostics: MarineRouteDiagnostics?
    var isEstimated: Bool
    var warnings: [String]
}

protocol MarineRoutingService: Sendable {
    func routeSummary(for request: MarineRouteRequest, destinationName: String) async throws -> MarineRouteSummary
}

protocol MarineRoutingProvider: Sendable {
    var kind: MarineRoutingProviderKind { get }
    func route(for request: MarineRouteRequest, destinationName: String) async throws -> MarineRouteSummary
}

enum MarineRoutingDocumentation {
    static let note = """
    Licensed marine routing requires chart-licensed topology, shallow areas, underwater hazards, vessel draft, bridges, restricted areas, speed restrictions, traffic separation schemes, and route-validation rules. Naviqa's current route is an estimated water route and must remain visually distinct from future licensed marine navigation.
    """
}

struct EstimatedWaterRouteService: MarineRoutingService, Sendable {
    private let provider: any MarineRoutingProvider

    init(provider: any MarineRoutingProvider = EstimatedWaterRoutingProvider()) {
        self.provider = provider
    }

    func routeSummary(for request: MarineRouteRequest, destinationName: String) async throws -> MarineRouteSummary {
        try await provider.route(for: request, destinationName: destinationName)
    }
}

struct EstimatedWaterRoutingProvider: MarineRoutingProvider, Sendable {
    enum RoutingError: LocalizedError {
        case invalidCoordinate
        case missingOrigin
        case endpointTooFarFromCoastalWater
        case noWaterPath
        case invalidGeometry

        var errorDescription: String? {
            switch self {
            case .invalidCoordinate:
                "The route contains an invalid coordinate."
            case .missingOrigin:
                "Choose an origin or allow Naviqa to use your current location."
            case .endpointTooFarFromCoastalWater, .noWaterPath, .invalidGeometry:
                "An estimated water route could not be calculated. Adjust the start or destination point and try again."
            }
        }
    }

    let kind: MarineRoutingProviderKind = .estimatedCoastalWater

    private let graph = CoastalWaterwayGraph()
    private let maxEndpointSnapNauticalMiles = 4.5

    func route(for request: MarineRouteRequest, destinationName: String) async throws -> MarineRouteSummary {
        let started = Date()
        try Task.checkCancellation()
        guard let origin = request.origin else {
            throw RoutingError.missingOrigin
        }
        let destination = request.destination
        guard origin.isValidRouteCoordinate, destination.isValidRouteCoordinate else {
            throw RoutingError.invalidCoordinate
        }

        let resolved = try graph.route(
            from: origin,
            to: destination,
            maxSnapDistanceNauticalMiles: maxEndpointSnapNauticalMiles
        )
        try Task.checkCancellation()

        let coordinates = removeConsecutiveDuplicates(resolved.coordinates)
        guard coordinates.count >= 4, coordinates.allSatisfy(\.isValidRouteCoordinate) else {
            throw RoutingError.invalidGeometry
        }

        let landIntersection = graph.validateNoKnownLandIntersection(coordinates)
        guard landIntersection == .clear else {
            Self.debugLog("Route rejected by land validation: \(landIntersection.description)")
            throw RoutingError.invalidGeometry
        }

        let routeDistance = Self.routeDistanceNauticalMiles(coordinates)
        guard routeDistance.isFinite, routeDistance > 0.1, routeDistance < 220 else {
            throw RoutingError.invalidGeometry
        }

        let estimate = RouteEstimateCalculator.calculate(
            RouteEstimateInput(
                distanceNauticalMiles: routeDistance,
                cruisingSpeedKnots: request.boatProfile?.preferredCruisingSpeedKnots ?? 18,
                fuelLitersPerNauticalMile: request.boatProfile?.estimatedFuelLitersPerNauticalMile,
                fuelLitersPerHour: request.boatProfile?.estimatedFuelLitersPerHour,
                fuelPricePerLiter: request.boatProfile?.fuelPricePerLiter,
                fuelRemainingLiters: request.boatProfile?.fuelRemainingLiters
            )
        )

        let diagnostics = MarineRouteDiagnostics(
            provider: kind,
            origin: origin,
            destination: destination,
            snappedOrigin: resolved.snappedOrigin.coordinate,
            snappedDestination: resolved.snappedDestination.coordinate,
            originSnapDistanceNauticalMiles: resolved.originSnapDistanceNauticalMiles,
            destinationSnapDistanceNauticalMiles: resolved.destinationSnapDistanceNauticalMiles,
            graphNodeCount: graph.nodeCount,
            graphEdgeCount: graph.edgeCount,
            startNodeID: resolved.snappedOrigin.id,
            endNodeID: resolved.snappedDestination.id,
            pathNodeCount: resolved.pathNodeIDs.count,
            finalCoordinateCount: coordinates.count,
            distanceNauticalMiles: routeDistance,
            calculationMilliseconds: Date().timeIntervalSince(started) * 1_000,
            landIntersectionResult: landIntersection.description
        )
        Self.debugLog(diagnostics.debugDescription)

        return MarineRouteSummary(
            destinationName: destinationName,
            distanceNauticalMiles: routeDistance,
            estimatedDurationSeconds: estimate.durationSeconds,
            estimatedFuelLiters: estimate.fuelUsedLiters,
            estimatedFuelCost: estimate.fuelCost,
            cruisingSpeedKnots: request.boatProfile?.preferredCruisingSpeedKnots ?? 18,
            boatName: request.boatProfile?.boatName,
            remainingRangeNauticalMiles: estimate.remainingRangeNauticalMiles,
            remainingHours: estimate.remainingHours,
            costPerNauticalMile: estimate.costPerNauticalMile,
            estimatedFuelRemainingAfterTripLiters: estimate.estimatedFuelRemainingAfterTripLiters,
            currencyCode: request.boatProfile?.currencyCode ?? "NOK",
            coordinates: coordinates,
            routeBounds: Self.region(containing: coordinates),
            routingSource: "Estimated coastal water",
            providerKind: kind,
            validationStatus: .passedEstimatedWaterConnectivity,
            constraintReport: .estimated,
            snappedOrigin: resolved.snappedOrigin.coordinate,
            snappedDestination: resolved.snappedDestination.coordinate,
            diagnostics: diagnostics,
            isEstimated: true,
            warnings: [
                "Estimated preview. Check official nautical charts before departure."
            ]
        )
    }

    static func routeDistanceNauticalMiles(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count > 1 else { return 0 }
        return zip(coordinates, coordinates.dropFirst()).reduce(0) { partialResult, pair in
            partialResult + haversineNauticalMiles(from: pair.0, to: pair.1)
        }
    }

    static func haversineNauticalMiles(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> Double {
        let radiusMeters = 6_371_000.0
        let lat1 = origin.latitude * .pi / 180
        let lat2 = destination.latitude * .pi / 180
        let deltaLat = (destination.latitude - origin.latitude) * .pi / 180
        let deltaLon = (destination.longitude - origin.longitude) * .pi / 180
        let a = sin(deltaLat / 2) * sin(deltaLat / 2) + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return (radiusMeters * c) / 1_852
    }

    static func region(containing coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let minLatitude = coordinates.map(\.latitude).min() ?? 60.3913
        let maxLatitude = coordinates.map(\.latitude).max() ?? 60.3913
        let minLongitude = coordinates.map(\.longitude).min() ?? 5.3221
        let maxLongitude = coordinates.map(\.longitude).max() ?? 5.3221
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.045, (maxLatitude - minLatitude) * 1.45),
                longitudeDelta: max(0.045, (maxLongitude - minLongitude) * 1.45)
            )
        )
    }

    private func removeConsecutiveDuplicates(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        coordinates.reduce(into: [CLLocationCoordinate2D]()) { result, coordinate in
            guard result.last?.isNear(coordinate) != true else { return }
            result.append(coordinate)
        }
    }

    private static func debugLog(_ message: String) {
        #if DEBUG
        print("Naviqa route diagnostics: \(message)")
        #endif
    }
}

private struct CoastalWaterwayGraph: Sendable {
    struct ResolvedRoute: Sendable {
        var coordinates: [CLLocationCoordinate2D]
        var snappedOrigin: WaterNode
        var snappedDestination: WaterNode
        var originSnapDistanceNauticalMiles: Double
        var destinationSnapDistanceNauticalMiles: Double
        var pathNodeIDs: [String]
    }

    enum LandIntersection: Equatable, Sendable {
        case clear
        case intersectsKnownLand(String)

        var description: String {
            switch self {
            case .clear:
                "clear"
            case .intersectsKnownLand(let name):
                "intersects \(name)"
            }
        }
    }

    var nodeCount: Int { nodes.count }
    var edgeCount: Int { edges.values.reduce(0) { $0 + $1.count } / 2 }

    private let nodes: [WaterNode] = [
        WaterNode(id: "bergen_harbour", coordinate: CLLocationCoordinate2D(latitude: 60.3913, longitude: 5.3221), role: .harbour),
        WaterNode(id: "puddefjorden", coordinate: CLLocationCoordinate2D(latitude: 60.3826, longitude: 5.3008), role: .coastalWater),
        WaterNode(id: "byfjorden_south", coordinate: CLLocationCoordinate2D(latitude: 60.3605, longitude: 5.2864), role: .coastalWater),
        WaterNode(id: "gravdalsvika", coordinate: CLLocationCoordinate2D(latitude: 60.3466, longitude: 5.2658), role: .coastalWater),
        WaterNode(id: "vatlestraumen_north", coordinate: CLLocationCoordinate2D(latitude: 60.3236, longitude: 5.2315), role: .channel),
        WaterNode(id: "vatlestraumen_south", coordinate: CLLocationCoordinate2D(latitude: 60.2943, longitude: 5.2052), role: .channel),
        WaterNode(id: "korsfjorden_north", coordinate: CLLocationCoordinate2D(latitude: 60.2770, longitude: 5.1855), role: .fjord),
        WaterNode(id: "korsfjorden_east", coordinate: CLLocationCoordinate2D(latitude: 60.2634, longitude: 5.1766), role: .fjord),
        WaterNode(id: "hjellestad_west", coordinate: CLLocationCoordinate2D(latitude: 60.2562, longitude: 5.2223), role: .coastalWater),
        WaterNode(id: "hjellestad_marina", coordinate: CLLocationCoordinate2D(latitude: 60.2552, longitude: 5.2361), role: .marina),
        WaterNode(id: "fanafjorden_outer", coordinate: CLLocationCoordinate2D(latitude: 60.2438, longitude: 5.2848), role: .fjord),
        WaterNode(id: "fanafjorden_inner", coordinate: CLLocationCoordinate2D(latitude: 60.2516, longitude: 5.3178), role: .fjord),
        WaterNode(id: "sotra_east", coordinate: CLLocationCoordinate2D(latitude: 60.3354, longitude: 5.1775), role: .coastalWater),
        WaterNode(id: "askoy_south", coordinate: CLLocationCoordinate2D(latitude: 60.3934, longitude: 5.2140), role: .coastalWater),
        WaterNode(id: "raunefjorden_north", coordinate: CLLocationCoordinate2D(latitude: 60.2248, longitude: 5.1424), role: .fjord),
        WaterNode(id: "raunefjorden_south", coordinate: CLLocationCoordinate2D(latitude: 60.1784, longitude: 5.0873), role: .fjord)
    ]

    private let edges: [String: [String]] = [
        "bergen_harbour": ["puddefjorden", "byfjorden_south"],
        "puddefjorden": ["bergen_harbour", "byfjorden_south"],
        "byfjorden_south": ["bergen_harbour", "puddefjorden", "gravdalsvika"],
        "gravdalsvika": ["byfjorden_south", "vatlestraumen_north", "sotra_east"],
        "vatlestraumen_north": ["gravdalsvika", "vatlestraumen_south"],
        "vatlestraumen_south": ["vatlestraumen_north", "korsfjorden_north"],
        "korsfjorden_north": ["vatlestraumen_south", "korsfjorden_east"],
        "korsfjorden_east": ["korsfjorden_north", "hjellestad_west", "fanafjorden_outer", "raunefjorden_north"],
        "hjellestad_west": ["korsfjorden_east", "hjellestad_marina"],
        "hjellestad_marina": ["hjellestad_west", "fanafjorden_outer"],
        "fanafjorden_outer": ["korsfjorden_east", "hjellestad_marina", "fanafjorden_inner"],
        "fanafjorden_inner": ["fanafjorden_outer"],
        "sotra_east": ["gravdalsvika", "askoy_south"],
        "askoy_south": ["sotra_east"],
        "raunefjorden_north": ["korsfjorden_east", "raunefjorden_south"],
        "raunefjorden_south": ["raunefjorden_north"]
    ]

    private let knownLandMasks: [LandMask] = [
        LandMask(name: "Laksevag peninsula", minLatitude: 60.3630, maxLatitude: 60.3910, minLongitude: 5.2500, maxLongitude: 5.2860),
        LandMask(name: "Fyllingsdalen landmass", minLatitude: 60.3000, maxLatitude: 60.3610, minLongitude: 5.2940, maxLongitude: 5.3650),
        LandMask(name: "Hjellestad shoreline", minLatitude: 60.2510, maxLatitude: 60.2645, minLongitude: 5.2368, maxLongitude: 5.2760),
        LandMask(name: "Sotra east landmass", minLatitude: 60.2860, maxLatitude: 60.3550, minLongitude: 5.0750, maxLongitude: 5.1700)
    ]

    func route(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, maxSnapDistanceNauticalMiles: Double) throws -> ResolvedRoute {
        guard let start = nearestNavigableNode(to: origin), let end = nearestNavigableNode(to: destination) else {
            throw EstimatedWaterRoutingProvider.RoutingError.endpointTooFarFromCoastalWater
        }
        guard start.distance <= maxSnapDistanceNauticalMiles, end.distance <= maxSnapDistanceNauticalMiles else {
            throw EstimatedWaterRoutingProvider.RoutingError.endpointTooFarFromCoastalWater
        }
        guard let path = shortestPath(from: start.node.id, to: end.node.id), path.count >= 2 else {
            throw EstimatedWaterRoutingProvider.RoutingError.noWaterPath
        }
        var coordinates = [start.node.coordinate]
        let graphCoordinates = path.compactMap(node(with:)).map(\.coordinate)
        coordinates.append(contentsOf: graphCoordinates)
        coordinates.append(end.node.coordinate)
        return ResolvedRoute(
            coordinates: coordinates,
            snappedOrigin: start.node,
            snappedDestination: end.node,
            originSnapDistanceNauticalMiles: start.distance,
            destinationSnapDistanceNauticalMiles: end.distance,
            pathNodeIDs: path
        )
    }

    func validateNoKnownLandIntersection(_ coordinates: [CLLocationCoordinate2D]) -> LandIntersection {
        for segment in zip(coordinates, coordinates.dropFirst()) {
            for mask in knownLandMasks where mask.segmentIntersects(segment.0, segment.1) {
                return .intersectsKnownLand(mask.name)
            }
        }
        return .clear
    }

    private func shortestPath(from start: String, to end: String) -> [String]? {
        var distances = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, Double.infinity) })
        var previous: [String: String] = [:]
        var unvisited = Set(nodes.map(\.id))
        distances[start] = 0

        while let current = unvisited.min(by: { (distances[$0] ?? .infinity) < (distances[$1] ?? .infinity) }) {
            if current == end { break }
            unvisited.remove(current)
            for neighbor in edges[current, default: []] where unvisited.contains(neighbor) {
                guard let currentNode = node(with: current), let neighborNode = node(with: neighbor) else { continue }
                let tentative = (distances[current] ?? .infinity) + currentNode.coordinate.distance(to: neighborNode.coordinate)
                if tentative < (distances[neighbor] ?? .infinity) {
                    distances[neighbor] = tentative
                    previous[neighbor] = current
                }
            }
        }

        guard distances[end] != .infinity else { return nil }
        var path = [end]
        var cursor = end
        while let next = previous[cursor] {
            path.append(next)
            cursor = next
        }
        return path.reversed()
    }

    private func nearestNavigableNode(to coordinate: CLLocationCoordinate2D) -> (node: WaterNode, distance: Double)? {
        nodes
            .filter { $0.role.isNavigableEndpoint }
            .map { node in
                (node, coordinate.distance(to: node.coordinate))
            }
            .min { $0.1 < $1.1 }
    }

    private func node(with id: String) -> WaterNode? {
        nodes.first { $0.id == id }
    }
}

private struct WaterNode: Sendable {
    enum Role: Sendable {
        case harbour
        case marina
        case coastalWater
        case channel
        case fjord

        var isNavigableEndpoint: Bool {
            switch self {
            case .harbour, .marina, .coastalWater, .channel, .fjord:
                true
            }
        }
    }

    var id: String
    var coordinate: CLLocationCoordinate2D
    var role: Role
}

private struct LandMask: Sendable {
    var name: String
    var minLatitude: CLLocationDegrees
    var maxLatitude: CLLocationDegrees
    var minLongitude: CLLocationDegrees
    var maxLongitude: CLLocationDegrees

    func segmentIntersects(_ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D) -> Bool {
        guard boundingBoxesOverlap(start, end) else { return false }
        if contains(start) || contains(end) { return true }
        let corners = [
            CLLocationCoordinate2D(latitude: minLatitude, longitude: minLongitude),
            CLLocationCoordinate2D(latitude: minLatitude, longitude: maxLongitude),
            CLLocationCoordinate2D(latitude: maxLatitude, longitude: maxLongitude),
            CLLocationCoordinate2D(latitude: maxLatitude, longitude: minLongitude)
        ]
        return zip(corners, corners.dropFirst() + [corners[0]]).contains { edge in
            segmentsIntersect(start, end, edge.0, edge.1)
        }
    }

    private func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (minLatitude...maxLatitude).contains(coordinate.latitude) && (minLongitude...maxLongitude).contains(coordinate.longitude)
    }

    private func boundingBoxesOverlap(_ start: CLLocationCoordinate2D, _ end: CLLocationCoordinate2D) -> Bool {
        let segmentMinLatitude = min(start.latitude, end.latitude)
        let segmentMaxLatitude = max(start.latitude, end.latitude)
        let segmentMinLongitude = min(start.longitude, end.longitude)
        let segmentMaxLongitude = max(start.longitude, end.longitude)
        return segmentMaxLatitude >= minLatitude
            && segmentMinLatitude <= maxLatitude
            && segmentMaxLongitude >= minLongitude
            && segmentMinLongitude <= maxLongitude
    }

    private func segmentsIntersect(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D, _ d: CLLocationCoordinate2D) -> Bool {
        let d1 = direction(a, b, c)
        let d2 = direction(a, b, d)
        let d3 = direction(c, d, a)
        let d4 = direction(c, d, b)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    private func direction(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D) -> Double {
        ((c.longitude - a.longitude) * (b.latitude - a.latitude)) - ((b.longitude - a.longitude) * (c.latitude - a.latitude))
    }
}

private extension MarineRouteDiagnostics {
    var debugDescription: String {
        "provider=\(provider.rawValue) origin=\(origin.latitude),\(origin.longitude) destination=\(destination.latitude),\(destination.longitude) snappedOrigin=\(snappedOrigin.latitude),\(snappedOrigin.longitude) snappedDestination=\(snappedDestination.latitude),\(snappedDestination.longitude) originSnapNM=\(originSnapDistanceNauticalMiles) destinationSnapNM=\(destinationSnapDistanceNauticalMiles) nodes=\(graphNodeCount) edges=\(graphEdgeCount) start=\(startNodeID) end=\(endNodeID) pathNodes=\(pathNodeCount) coordinates=\(finalCoordinateCount) distanceNM=\(distanceNauticalMiles) land=\(landIntersectionResult) durationMS=\(calculationMilliseconds)"
    }
}

extension CLLocationCoordinate2D: @retroactive @unchecked Sendable {}

extension CLLocationCoordinate2D {
    var isValidRouteCoordinate: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180
    }

    func isNear(_ other: CLLocationCoordinate2D) -> Bool {
        abs(latitude - other.latitude) < 0.00001 && abs(longitude - other.longitude) < 0.00001
    }

    func distance(to other: CLLocationCoordinate2D) -> Double {
        EstimatedWaterRoutingProvider.haversineNauticalMiles(from: self, to: other)
    }
}
