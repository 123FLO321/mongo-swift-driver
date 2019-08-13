import Foundation
@testable import MongoSwift
import Nimble
import XCTest

/// Protocol that test cases which configure fail points during their execution conform to.
internal protocol FailPointConfigured: class {
    /// The fail point currently set, if one exists.
    var activeFailPoint: FailPoint? { get set }
}

extension FailPointConfigured {
    /// Sets the active fail point to the provided fail point and enables it.
    internal func activateFailPoint(_ failPoint: FailPoint) throws {
        self.activeFailPoint = failPoint
        try self.activeFailPoint?.enable()
    }

    /// If a fail point is active, it is disabled and cleared.
    internal func disableActiveFailPoint() {
        if let failPoint = self.activeFailPoint {
            failPoint.disable()
            self.activeFailPoint = nil
        }
    }
}

/// Struct modeling a MongoDB fail point.
internal struct FailPoint: Decodable {
    private var failPoint: Document

    /// The fail point being configured.
    internal var name: String {
        return self.failPoint["configureFailPoint"] as? String ?? ""
    }

    public init(from decoder: Decoder) throws {
        self.failPoint = try Document(from: decoder)
    }

    internal func enable() throws {
        var commandDoc = ["configureFailPoint": self.failPoint["configureFailPoint"]!] as Document
        for (k, v) in self.failPoint {
            guard k != "configureFailPoint" else {
                continue
            }

            // Need to convert error codes to int32's due to c driver bug (CDRIVER-3121)
            if k == "data",
               var data = v as? Document,
               var wcErr = data["writeConcernError"] as? Document,
               let code = wcErr["code"] as? BSONNumber {
                wcErr["code"] = code.int32Value
                data["writeConcernError"] = wcErr
                commandDoc["data"] = data
            } else {
                commandDoc[k] = v
            }
        }
        let client = try MongoClient()
        try client.db("admin").runCommand(commandDoc)
    }

    internal func disable() {
        do {
            let client = try MongoClient()
            try client.db("admin").runCommand(["configureFailPoint": self.name, "mode": "off"])
        } catch {
            print("Failed to disable fail point \(self.name): \(error)")
        }
    }
}

/// A struct representing a server version.
internal struct ServerVersion: Comparable, Decodable {
    let major: Int
    let minor: Int
    let patch: Int

    /// initialize a server version from a string
    init(_ str: String) throws {
        let versionComponents = str.split(separator: ".").prefix(3)
        guard versionComponents.count >= 2 else {
            throw TestError(message: "Expected version string \(str) to have at least two .-separated components")
        }

        guard let major = Int(versionComponents[0]) else {
            throw TestError(message: "Error parsing major version from \(str)")
        }
        guard let minor = Int(versionComponents[1]) else {
            throw TestError(message: "Error parsing minor version from \(str)")
        }

        var patch = 0
        if versionComponents.count == 3 {
            // in case there is text at the end, for ex "3.6.0-rc1", stop first time
            /// we encounter a non-numeric character.
            let numbersOnly = versionComponents[2].prefix { "0123456789".contains($0) }
            guard let patchValue = Int(numbersOnly) else {
                throw TestError(message: "Error parsing patch version from \(str)")
            }
            patch = patchValue
        }

        self.init(major: major, minor: minor, patch: patch)
    }

    init(from decoder: Decoder) throws {
        let str = try decoder.singleValueContainer().decode(String.self)
        try self.init(str)
    }

    // initialize given major, minor, and optional patch
    init(major: Int, minor: Int, patch: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch ?? 0
    }

    static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        } else if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        } else {
            return lhs.patch < rhs.patch
        }
    }
}

/// Struct representing conditions that a deployment must meet in order for a test file to be run.
internal struct TestRequirement: Decodable {
    private let minServerVersion: ServerVersion?
    private let maxServerVersion: ServerVersion?
    private let topology: [String]?

    /// Determines if the given deployment meets this requirement.
    func isMet(by version: ServerVersion, _ topology: TopologyDescription.TopologyType) -> Bool {
        if let minVersion = self.minServerVersion {
            guard minVersion <= version else {
                return false
            }
        }
        if let maxVersion = self.maxServerVersion {
            guard maxVersion >= version else {
                return false
            }
        }
        if let topologies = self.topology?.map({ TopologyDescription.TopologyType(from: $0) }) {
            guard topologies.contains(topology) else {
                return false
            }
        }
        return true
    }
}

/// Struct representing the contents of a collection after a spec test has been run.
internal struct CollectionTestInfo: Decodable {
    /// An optional name specifying a collection whose documents match the `data` field of this struct.
    /// If nil, whatever collection used in the test should be used instead.
    let name: String?

    /// The documents found in the collection.
    let data: [Document]
}

/// Struct representing an "outcome" defined in a spec test.
internal struct TestOutcome: Decodable {
    /// Whether an error is expected or not.
    let error: Bool?

    /// The expected result of running the operation associated with this test.
    let result: TestOperationResult?

    /// The expected state of the collection at the end of the test.
    let collection: CollectionTestInfo
}

/// Protocol defining the behavior of an individual spec test.
internal protocol SpecTest {
    var description: String { get }
    var outcome: TestOutcome { get }
    var operation: AnyTestOperation { get }

    /// Runs the operation with the given context and performs assertions on the result based upon the expected outcome.
    func run(client: MongoClient,
             db: MongoDatabase,
             collection: MongoCollection<Document>,
             session: ClientSession?) throws
}

/// Default implementation of a test execution.
extension SpecTest {
    internal func run(client: MongoClient,
                      db: MongoDatabase,
                      collection: MongoCollection<Document>,
                      session: ClientSession?) throws {
        var result: TestOperationResult?
        var seenError: Error?
        do {
            result = try self.operation.op.execute(
                    client: client,
                    database: db,
                    collection: collection,
                    session: session)
        } catch {
            if case let ServerError.bulkWriteError(_, _, _, bulkResult, _) = error {
                result = TestOperationResult(from: bulkResult)
            }
            seenError = error
        }

        if self.outcome.error ?? false {
            expect(seenError).toNot(beNil(), description: self.description)
        } else {
            expect(seenError).to(beNil(), description: self.description)
        }

        if let expectedResult = self.outcome.result {
            expect(result).toNot(beNil())
            expect(result).to(equal(expectedResult))
        }
        let verifyColl = db.collection(self.outcome.collection.name ?? collection.name)
        let foundDocs = try Array(verifyColl.find())
        expect(foundDocs.count).to(equal(self.outcome.collection.data.count))
        zip(foundDocs, self.outcome.collection.data).forEach {
            expect($0).to(sortedEqual($1), description: self.description)
        }
    }
}
