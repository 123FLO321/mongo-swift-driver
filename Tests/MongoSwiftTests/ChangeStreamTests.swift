import mongoc
@testable import MongoSwift
import Nimble
import XCTest

/// The entity on which to start a change stream.
internal enum ChangeStreamTarget: String, Decodable {
    /// Indicates the change stream will be opened to watch a `MongoClient`.
    case client

    /// Indicates the change stream will be opened to watch a `MongoDatabase`.
    case database

    /// Indicates the change stream will be opened to watch a `MongoCollection`.
    case collection

    /// Open a change stream against this target. An error will be thrown if the necessary namespace information is not
    /// provided.
    internal func watch(_ client: MongoClient,
                        _ database: String?,
                        _ collection: String?,
                        _ pipeline: [Document],
                        _ options: ChangeStreamOptions) throws -> ChangeStream<Document> {
        switch self {
        case .client:
            return try client.watch(pipeline, options: options, withEventType: Document.self)
        case .database:
            guard let database = database else {
                throw RuntimeError.internalError(message: "missing db in watch")
            }
            return try client.db(database).watch(pipeline, options: options, withEventType: Document.self)
        case .collection:
            guard let collection = collection, let database = database else {
                throw RuntimeError.internalError(message: "missing db or collection in watch")
            }
            return try client.db(database)
                    .collection(collection)
                    .watch(pipeline, options: options, withEventType: Document.self)
        }
    }
}

/// An operation performed as part of a `ChangeStreamTest` (e.g. a CRUD operation, an drop, etc.)
/// This struct includes the namespace against which it should be run.
internal struct ChangeStreamTestOperation: Decodable {
    /// The operation itself to run.
    private let operation: AnyTestOperation

    /// The database to run the operation against.
    private let database: String

    /// The collection to run the operation against.
    private let collection: String

    private enum CodingKeys: String, CodingKey {
        case database, collection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.database = try container.decode(String.self, forKey: .database)
        self.collection = try container.decode(String.self, forKey: .collection)
        self.operation = try AnyTestOperation(from: decoder)
    }

    /// Run the operation against the namespace associated with this operation.
    internal func execute(using client: MongoClient) throws -> TestOperationResult? {
        let db = client.db(self.database)
        let coll = db.collection(self.collection)
        return try self.operation.op.execute(client: client, database: db, collection: coll, session: nil)
    }
}

/// The outcome of a given `ChangeStreamTest`.
internal enum ChangeStreamTestResult: Decodable {
    /// Describes an error received during the test
    case error(code: Int, labels: [String]?)

    /// An array of event documents expected to be received from the change stream without error during the test.
    case success([Document])

    /// Top-level coding keys. Used for determining whether this result is a success or failure.
    internal enum CodingKeys: CodingKey {
        case error, success
    }

    /// Coding keys used specifically for decoding the `.error` case.
    internal enum ErrorCodingKeys: CodingKey {
        case code, errorLabels
    }

    /// Asserts that the given error matches the one expected by this result.
    internal func assertMatchesError(error: Error, description: String) {
        guard case let .error(code, labels) = self else {
            fail("\(description) failed: got error but result success")
            return
        }
        guard case let ServerError.commandError(seenCode, _, _, seenLabels) = error else {
            fail("\(description) failed: didn't get command error")
            return
        }

        expect(code).to(equal(seenCode), description: description)
        if let labels = labels {
            expect(seenLabels).toNot(beNil(), description: description)
            expect(seenLabels).to(equal(labels), description: description)
        } else {
            expect(seenLabels).to(beNil(), description: description)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.success) {
            self = .success(try container.decode([Document].self, forKey: .success))
        } else {
            let nested = try container.nestedContainer(keyedBy: ErrorCodingKeys.self, forKey: .error)
            let code = try nested.decode(Int.self, forKey: .code)
            let labels = try nested.decodeIfPresent([String].self, forKey: .errorLabels)
            self = .error(code: code, labels: labels)
        }
    }
}

/// Struct representing a single test within a spec test JSON file.
internal struct ChangeStreamTest: Decodable {
    /// The title of this test.
    let description: String

    /// The minimum server version that this test can be run against.
    let minServerVersion: ServerVersion

    /// The fail point that should be set prior to running this test.
    let failPoint: FailPoint?

    /// The entity on which to run the change stream.
    let target: ChangeStreamTarget

    /// An array of server topologies against which to run the test.
    let topology: [String]

    /// An array of additional aggregation pipeline stages to pass to the `watch` used to create the change stream for
    /// this test.
    let changeStreamPipeline: [Document]

    /// Additional options to pass to the `watch` used to create the change stream for this test.
    let changeStreamOptions: ChangeStreamOptions

    /// An array of documents, each describing an operation that should be run as part of this test.
    let operations: [ChangeStreamTestOperation]

    /// A list of command-started events that are expected to have been emitted by the client that starts the change
    /// stream for this test.
    let expectations: [TestCommandStartedEvent]?

    // The expected result of running this test.
    let result: ChangeStreamTestResult

    internal func run(globalClient: MongoClient, database: String, collection: String) throws {
        let client = try MongoClient.makeTestClient(options: ClientOptions(commandMonitoring: true))

        let center = client.notificationCenter
        var events: [TestCommandStartedEvent] = []
        let observer = center.addObserver(forName: .commandStarted, object: nil, queue: nil) { notification in
            guard let event = notification.userInfo?["event"] as? CommandStartedEvent else {
                fail("\(self.description) failed: bad event type")
                return
            }
            guard event.commandName != "isMaster" else {
                return
            }
            events.append(TestCommandStartedEvent(from: event))
        }
        defer { client.notificationCenter.removeObserver(observer) }

        do {
            let changeStream = try self.target.watch(client,
                                                     database,
                                                     collection,
                                                     self.changeStreamPipeline,
                                                     self.changeStreamOptions)
            for operation in self.operations {
                _ = try operation.execute(using: globalClient)
            }

            switch self.result {
            case .error:
                _ = try changeStream.nextOrError()
                fail("\(self.description) failed: expected error but got none while iterating")
            case let .success(events):
                var seenEvents: [Document] = []
                for _ in 0..<events.count {
                    let event = try changeStream.nextOrError()
                    expect(event).toNot(beNil(), description: description)
                    seenEvents.append(event!)
                }
                expect(seenEvents).to(match(events), description: self.description)
            }
        } catch {
            self.result.assertMatchesError(error: error, description: self.description)
        }

        if let expectations = self.expectations {
            expect(events).to(match(expectations), description: self.description)
        }
    }
}

/// Struct representing a single change-streams spec test JSON file.
private struct ChangeStreamTestFile: Decodable {
    private enum CodingKeys: String, CodingKey {
        case databaseName = "database_name",
             collectionName = "collection_name",
             database2Name = "database2_name",
             collection2Name = "collection2_name",
             tests
    }

    /// Name of this test case.
    var name: String = ""

    /// The default database.
    let databaseName: String

    /// The default collection.
    let collectionName: String

    /// Secondary database.
    let database2Name: String

    // Secondary collection.
    let collection2Name: String

    /// An array of tests that are to be run independently of each other.
    let tests: [ChangeStreamTest]
}

/// Class covering the JSON spec tests associated with change streams.
final class ChangeStreamSpecTests: MongoSwiftTestCase, FailPointConfigured {
    var activeFailPoint: FailPoint?

    override func tearDown() {
        // This is included here to clear any fail points left over after a test failure.
        self.disableActiveFailPoint()
    }

    func testChangeStreamSpec() throws {
        // TODO SWIFT-539: unskip
        if MongoSwiftTestCase.ssl && MongoSwiftTestCase.isMacOS {
            print("Skipping test, fails with SSL, see CDRIVER-3318")
            return
        }

        let testFilesPath = MongoSwiftTestCase.specsPath + "/change-streams/tests"
        let testFiles: [String] = try FileManager.default.contentsOfDirectory(atPath: testFilesPath)

        let tests: [ChangeStreamTestFile] = try testFiles.map { fileName in
            let url = URL(fileURLWithPath: "\(testFilesPath)/\(fileName)")
            var testFile = try BSONDecoder().decode(ChangeStreamTestFile.self, from: Document(fromJSONFile: url))

            testFile.name = fileName
            return testFile
        }

        let globalClient = try MongoClient.makeTestClient()

        let version = try globalClient.serverVersion()
        let topology = MongoSwiftTestCase.topologyType

        for testFile in tests {
            let db1 = globalClient.db(testFile.databaseName)
            let db2 = globalClient.db(testFile.database2Name)
            defer {
                try? db1.drop()
                try? db2.drop()
            }
            print("\n------------\nExecuting tests from file \(testFilesPath)/\(testFile.name)...\n")
            for test in testFile.tests {
                let testTopologies = test.topology.map { TopologyDescription.TopologyType(from: $0) }
                guard testTopologies.contains(topology) else {
                    print("Skipping test case \"\(test.description)\": unsupported topology type \(topology)")
                    continue
                }

                guard version >= test.minServerVersion else {
                    print("Skipping tests case \"\(test.description)\": minimum required server " +
                                  "version \(test.minServerVersion) not met.")
                    continue
                }

                print("Executing test: \(test.description)")

                try db1.drop()
                try db2.drop()
                _ = try db1.createCollection(testFile.collectionName)
                _ = try db2.createCollection(testFile.collection2Name)

                if let failPoint = test.failPoint {
                    try self.activateFailPoint(failPoint)
                }
                defer { self.disableActiveFailPoint() }

                try test.run(globalClient: globalClient,
                             database: testFile.databaseName,
                             collection: testFile.collectionName
                )
            }
        }
    }
}

/// Class for spec prose tests and other integration tests associated with change streams.
final class ChangeStreamTests: MongoSwiftTestCase {
    func testChangeStreamOnAClient() throws {
        guard MongoSwiftTestCase.topologyType != .single else {
            print("Skipping test case because of unsupported topology type \(MongoSwiftTestCase.topologyType)")
            return
        }

        let client = try MongoClient.makeTestClient()
        guard try client.serverVersion() >= ServerVersion(major: 4, minor: 0) else {
            print("Skipping test case for server version \(try client.serverVersion())")
            return
        }

        let changeStream = try client.watch()

        let db1 = client.db("db1")
        defer { try? db1.drop() }
        let coll1 = db1.collection("coll1")
        let coll2 = db1.collection("coll2")
        let doc1: Document = ["_id": 1, "a": 1]
        let doc2: Document = ["_id": 2, "x": 123]
        try coll1.insertOne(doc1)
        try coll2.insertOne(doc2)

        let change1 = changeStream.next()
        expect(change1).toNot(beNil())
        expect(change1?.operationType).to(equal(.insert))
        expect(change1?.fullDocument).to(equal(doc1))
        //expect the resumeToken to be updated to the _id field of the most recently accessed document
        expect(changeStream.resumeToken).to(equal(change1?._id))

        // test that a change exists for a different collection in the same database
        let change2 = changeStream.next()
        expect(change2).toNot(beNil())
        expect(change2?.operationType).to(equal(.insert))
        expect(change2?.fullDocument).to(equal(doc2))
        // expect the resumeToken to be updated to the _id field of the most recently accessed document
        expect(changeStream.resumeToken).to(equal(change2?._id))

        // test that a change exists for a collection in a different database
        let db2 = client.db("db2")
        defer { try? db2.drop() }
        let coll = db2.collection("coll3")
        let doc3: Document = ["_id": 3, "y": 321]
        try coll.insertOne(doc3)
        let change3 = changeStream.next()
        expect(change3).toNot(beNil())
        expect(change3?.operationType).to(equal(.insert))
        expect(change3?.fullDocument).to(equal(doc3))
        // expect the resumeToken to be updated to the _id field of the most recently accessed document
        expect(changeStream.resumeToken).to(equal(change3?._id))
    }

    func testChangeStreamOnADatabase() throws {
        guard MongoSwiftTestCase.topologyType != .single else {
            print("Skipping test case because of unsupported topology type \(MongoSwiftTestCase.topologyType)")
            return
        }

        let client = try MongoClient.makeTestClient()
        guard try client.serverVersion() >= ServerVersion(major: 4, minor: 0) else {
            print("Skipping test case for server version \(try client.serverVersion())")
            return
        }

        let db = client.db(type(of: self).testDatabase)
        defer { try? db.drop() }
        let changeStream = try db.watch()

        // expect the first iteration to be nil since no changes have been made to the database.
        expect(changeStream.next()).to(beNil())

        let coll = db.collection(self.getCollectionName(suffix: "1"))
        let doc1: Document = ["_id": 1, "a": 1]
        try coll.insertOne(doc1)

        // test that the change stream contains a change document for the `insert` operation
        let change1 = changeStream.next()
        expect(change1).toNot(beNil())
        expect(change1?.operationType).to(equal(.insert))
        expect(change1?.fullDocument).to(equal(doc1))

        // expect the resumeToken to be updated to the _id field of the most recently accessed document
        expect(changeStream.resumeToken).to(equal(change1?._id))

        // expect the change stream to contain a change document for the `drop` operation
        try db.drop()
        let change2 = changeStream.next()
        expect(change2).toNot(beNil())
        expect(change2?.operationType).to(equal(.drop))

        // expect the resumeToken to be updated to the _id field of the most recently accessed document
        expect(changeStream.resumeToken).to(equal(change2?._id))
    }

    func testChangeStreamOnACollection() throws {
        guard MongoSwiftTestCase.topologyType != .single else {
            print("Skipping test case because of unsupported topology type \(MongoSwiftTestCase.topologyType)")
            return
        }

        let client = try MongoClient.makeTestClient()
        let db = client.db(type(of: self).testDatabase)
        defer { try? db.drop() }
        let coll = try db.createCollection(self.getCollectionName(suffix: "1"))
        let options = ChangeStreamOptions(fullDocument: .updateLookup)
        let changeStream = try coll.watch(options: options)

        let doc: Document = ["_id": 1, "x": 1]
        try coll.insertOne(doc)
        let change1 = changeStream.next()
        // expect the change stream to contain a change document for the `insert` operation
        expect(change1).toNot(beNil())
        expect(change1?.operationType).to(equal(.insert))
        expect(change1?.fullDocument).to(equal(doc))

        // expect the resumeToken to be updated to the _id field of the most recently accessed document
        expect(changeStream.resumeToken).to(equal(change1?._id))

        try coll.updateOne(filter: ["x": 1], update: ["$set": ["x": 2] as Document])
        let change2 = changeStream.next()
        // expect the change stream to contain a change document for the `update` operation
        expect(change2).toNot(beNil())
        expect(change2?.operationType).to(equal(.update))
        expect(change2?.fullDocument).to(equal(["_id": 1, "x": 2]))

        // expect the resumeToken to be updated to the _id field of the most recently accessed document
        expect(changeStream.resumeToken).to(equal(change2?._id))

        // expect the change stream contains a change document for the `find` operation
        try coll.findOneAndDelete(["x": 2])
        let change3 = changeStream.next()
        expect(change3).toNot(beNil())
        expect(change3?.operationType).to(equal(.delete))

        // expect the resumeToken to be updated to the _id field of the most recently accessed document
        expect(changeStream.resumeToken).to(equal(change3?._id))
    }

    func testChangeStreamWithPipeline() throws {
        guard MongoSwiftTestCase.topologyType != .single else {
            print("Skipping test case because of unsupported topology type \(MongoSwiftTestCase.topologyType)")
            return
        }

        let client = try MongoClient.makeTestClient()
        let db = client.db(type(of: self).testDatabase)
        defer { try? db.drop() }
        let coll = try db.createCollection(self.getCollectionName(suffix: "1"))
        let options = ChangeStreamOptions(fullDocument: .updateLookup)
        let pipeline: [Document] = [["$match": ["fullDocument.a": 1] as Document]]
        let changeStream = try coll.watch(pipeline, options: options)

        let doc1: Document = ["_id": 1, "a": 1]
        try coll.insertOne(doc1)
        let change1 = changeStream.next()

        expect(change1).toNot(beNil())
        expect(change1?.operationType).to(equal(.insert))
        expect(change1?.fullDocument).to(equal(doc1))
        // test that a change event does not exists for this insert since this field's been excluded by the pipeline.
        try coll.insertOne(["b": 2])
        let change2 = changeStream.next()
        expect(change2).to(beNil())
    }

    func testChangeStreamResumeToken() throws {
        guard MongoSwiftTestCase.topologyType != .single else {
            print("Skipping test case because of unsupported topology type \(MongoSwiftTestCase.topologyType)")
            return
        }

        let client = try MongoClient.makeTestClient()
        let db = client.db(type(of: self).testDatabase)
        defer { try? db.drop() }
        let coll = try db.createCollection(self.getCollectionName(suffix: "1"))
        let changeStream1 = try coll.watch()
        try coll.insertOne(["x": 1])
        try coll.insertOne(["y": 2])
        _ = changeStream1.next()
        expect(changeStream1.error).to(beNil())
        // save the current resumeToken and use it as the resumeAfter in a new change stream
        let resumeAfter = changeStream1.resumeToken
        let changeStream2 = try coll.watch(options: ChangeStreamOptions(resumeAfter: resumeAfter))
        // expect this change stream to have its resumeToken set to the resumeAfter
        expect(changeStream2.resumeToken).to(equal(resumeAfter))
        // expect this change stream to have more events after resuming
        expect(changeStream2.next()).toNot(beNil())
        expect(changeStream2.error).to(beNil())
    }

    func testChangeStreamProjectOutIdError() throws {
         guard MongoSwiftTestCase.topologyType != .single else {
            print("Skipping test case because of unsupported topology type \(MongoSwiftTestCase.topologyType)")
            return
        }

        let client = try MongoClient.makeTestClient()
        let db = client.db(type(of: self).testDatabase)
        defer { try? db.drop() }
        let coll = try db.createCollection(self.getCollectionName(suffix: "1"))
        let options = ChangeStreamOptions(fullDocument: .updateLookup)
        let pipeline: [Document] = [["$project": ["_id": 0] as Document]]
        let changeStream = try coll.watch(pipeline, options: options)
        try coll.insertOne(["a": 1])
        expect(try changeStream.nextOrError()).to(throwError())
    }

    struct MyFullDocumentType: Codable, Equatable {
        let id: Int
        let x: Int
        let y: Int

        enum CodingKeys: String, CodingKey {
            case id = "_id", x, y
        }
    }

    struct MyEventType: Codable, Equatable {
        let id: Document
        let operation: String
        let fullDocument: MyFullDocumentType
        let nameSpace: Document
        let updateDescription: Document?

        enum CodingKeys: String, CodingKey {
            case id = "_id", operation = "operationType", fullDocument, nameSpace = "ns", updateDescription
        }
    }

    func testChangeStreamWithEventType() throws {
        guard MongoSwiftTestCase.topologyType != .single else {
            print("Skipping test case because of unsupported topology type \(MongoSwiftTestCase.topologyType)")
            return
        }

        let client = try MongoClient.makeTestClient()
        let db = client.db(type(of: self).testDatabase)
        defer { try? db.drop() }
        let coll = try db.createCollection(self.getCollectionName(suffix: "1"))

        // test that the change stream works on a collection when using withEventType
        let collChangeStream = try coll.watch(withEventType: MyEventType.self)
        let doc: Document = ["_id": 1, "x": 1, "y": 2]
        try coll.insertOne(doc)
        let collChange = collChangeStream.next()
        expect(collChangeStream.error).to(beNil())
        expect(collChange).toNot(beNil())
        expect(collChange?.operation).to(equal("insert"))
        expect(collChange?.fullDocument).to(equal(MyFullDocumentType(id: 1, x: 1, y: 2)))

        guard try client.serverVersion() >= ServerVersion(major: 4, minor: 0) else {
            print("Skipping test case for server version \(try client.serverVersion())")
            return
        }

        // test that the change stream works on client and database when using withEventType
        let clientChangeStream = try client.watch(withEventType: MyEventType.self)
        let dbChangeStream = try db.watch(withEventType: MyEventType.self)
        let expectedFullDocument = MyFullDocumentType(id: 2, x: 1, y: 2)
        try coll.insertOne(["_id": 2, "x": 1, "y": 2])
        let clientChange = clientChangeStream.next()
        let dbChange = dbChangeStream.next()
        expect(clientChangeStream).toNot(beNil())
        expect(clientChangeStream.error).to(beNil())
        expect(clientChange?.operation).to(equal("insert"))
        expect(clientChange?.fullDocument).to(equal(expectedFullDocument))
        expect(dbChangeStream).toNot(beNil())
        expect(dbChangeStream.error).to(beNil())
        expect(dbChange?.operation).to(equal("insert"))
        expect(dbChange?.fullDocument).to(equal(expectedFullDocument))
    }

    func testChangeStreamWithFullDocumentType() throws {
         guard MongoSwiftTestCase.topologyType != .single else {
            print("Skipping test case because of unsupported topology type \(MongoSwiftTestCase.topologyType)")
            return
        }

        let expectedDoc1 = MyFullDocumentType(id: 1, x: 1, y: 2)

        let client = try MongoClient.makeTestClient()
        let db = client.db(type(of: self).testDatabase)
        defer { try? db.drop() }

        let coll = try db.createCollection(self.getCollectionName(suffix: "1"))

        // test that the change stream works on a collection when using withFullDocumentType
        let collChangeStream = try coll.watch(withFullDocumentType: MyFullDocumentType.self)
        try coll.insertOne(["_id": 1, "x": 1, "y": 2])
        let collChange = collChangeStream.next()
        expect(collChange?.fullDocument).to(equal(expectedDoc1))

        guard try client.serverVersion() >= ServerVersion(major: 4, minor: 0) else {
            print("Skipping test case for server version \(try client.serverVersion())")
            return
        }

        // test that the change stream works on client and database when using withFullDocumentType
        let clientChangeStream = try client.watch(withFullDocumentType: MyFullDocumentType.self)
        let dbChangeStream = try db.watch(withFullDocumentType: MyFullDocumentType.self)
        let expectedDoc2 = MyFullDocumentType(id: 2, x: 1, y: 2)
        try coll.insertOne(["_id": 2, "x": 1, "y": 2])
        let clientChange = clientChangeStream.next()
        let dbChange = dbChangeStream.next()
        expect(clientChange?.fullDocument).to(equal(expectedDoc2))
        expect(dbChange?.fullDocument).to(equal(expectedDoc2))
    }

    struct MyType: Codable, Equatable {
        let foo: String
        let bar: Int
    }

    func testChangeStreamOnACollectionWithCodableType() throws {
        guard MongoSwiftTestCase.topologyType != .single else {
            print("Skipping test case because of unsupported topology type \(MongoSwiftTestCase.topologyType)")
            return
        }

        let client = try MongoClient.makeTestClient()
        let db = client.db(type(of: self).testDatabase)
        defer { try? db.drop() }

        let coll = try db.createCollection(self.getCollectionName(suffix: "1"), withType: MyType.self)
        let options = ChangeStreamOptions(fullDocument: .updateLookup)
        let changeStream = try coll.watch(options: options)

        let myType = MyType(foo: "blah", bar: 123)
        try coll.insertOne(myType)
        let change1 = changeStream.next()
        expect(changeStream.error).to(beNil())
        expect(change1).toNot(beNil())
        expect(change1?.operationType).to(equal(.insert))
        expect(change1?.fullDocument).to(equal(myType))
    }
}
