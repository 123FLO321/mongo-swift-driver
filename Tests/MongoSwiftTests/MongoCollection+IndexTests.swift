@testable import MongoSwift
import Nimble
import XCTest

private var _client: MongoClient?

final class MongoCollection_IndexTests: MongoSwiftTestCase {
    var collName: String = ""
    var coll: MongoCollection<Document>!
    let doc1: Document = ["_id": 1, "cat": "dog"]
    let doc2: Document = ["_id": 2, "cat": "cat"]

    /// Set up the entire suite - run once before all tests
    override class func setUp() {
        super.setUp()
        do {
            _client = try MongoClient.makeTestClient()
        } catch {
            print("Setup failed: \(error)")
        }
    }

    /// Set up a single test - run before each testX function
    override func setUp() {
        super.setUp()
        self.continueAfterFailure = false
        self.collName = self.getCollectionName()

        do {
            guard let client = _client else {
                XCTFail("Invalid client")
                return
            }
            coll = try client.db(type(of: self).testDatabase).createCollection(self.collName)
            try coll.insertMany([doc1, doc2])
        } catch {
            XCTFail("Setup failed: \(error)")
        }
    }

    /// Teardown a single test - run after each testX function
    override func tearDown() {
        super.tearDown()
        do {
            if coll != nil { try coll.drop() }
        } catch {
            XCTFail("Dropping test collection \(type(of: self).testDatabase).\(self.collName) failed: \(error)")
        }
    }

    /// Teardown the entire suite - run after all tests complete
    override class func tearDown() {
        super.tearDown()
        do {
            guard let client = _client else {
                print("Invalid client")
                return
            }
            try client.db(self.testDatabase).drop()
        } catch {
            print("Dropping test database \(self.testDatabase) failed: \(error)")
        }
    }

    func testCreateIndexFromModel() throws {
        let model = IndexModel(keys: ["cat": 1])
        expect(try self.coll.createIndex(model)).to(equal("cat_1"))
        let indexes = try coll.listIndexes()
        expect(indexes.next()?["name"]).to(bsonEqual("_id_"))
        expect(indexes.next()?["name"]).to(bsonEqual("cat_1"))
        expect(indexes.next()).to(beNil())
    }

    func testIndexOptions() throws {
        // TODO SWIFT-539: unskip
        if MongoSwiftTestCase.ssl && MongoSwiftTestCase.isMacOS {
            print("Skipping test, fails with SSL, see CDRIVER-3318")
            return
        }

        let options = IndexOptions(
            background: true,
            name: "testOptions",
            sparse: false,
            storageEngine: ["wiredTiger": ["configString": "access_pattern_hint=random"] as Document],
            unique: true,
            indexVersion: 2,
            defaultLanguage: "english",
            languageOverride: "cat",
            textIndexVersion: 2,
            weights: ["cat": 0.5, "_id": 0.5],
            sphereIndexVersion: 2,
            bits: 32,
            max: 30,
            min: 0,
            bucketSize: 10,
            collation: ["locale": "fr"]
        )

        let model = IndexModel(keys: ["cat": 1, "_id": -1], options: options)
        expect(try self.coll.createIndex(model)).to(equal("testOptions"))

        let ttlOptions = IndexOptions(expireAfterSeconds: 100, name: "ttl")
        let ttlModel = IndexModel(keys: ["cat": 1], options: ttlOptions)
        expect(try self.coll.createIndex(ttlModel)).to(equal("ttl"))

        var indexes: [IndexOptions] = try self.coll.listIndexes().map { indexDoc in
            var decoded = try BSONDecoder().decode(IndexOptions.self, from: indexDoc)
            // name is not one of the CodingKeys for IndexOptions so manually pull
            // it out of the doc and set it on the options.
            decoded.name = indexDoc.name as? String
            return decoded
        }

        indexes.sort { $0.name! < $1.name! }
        expect(indexes).to(haveCount(3))

        // _id index
        expect(indexes[0]).to(equal(IndexOptions(name: "_id_", indexVersion: 2)))

        // testOptions index
        var expectedTestOptions = options
        expectedTestOptions.name = "testOptions"
        expect(indexes[1]).to(equal(expectedTestOptions))

        // ttl index
        var expectedTtlOptions = ttlOptions
        expectedTtlOptions.indexVersion = 2
        expect(indexes[2]).to(equal(expectedTtlOptions))
    }

    func testCreateIndexesFromModels() throws {
        let model1 = IndexModel(keys: ["cat": 1])
        let model2 = IndexModel(keys: ["cat": -1])
        expect( try self.coll.createIndexes([model1, model2]) ).to(equal(["cat_1", "cat_-1"]))
        let indexes = try coll.listIndexes()
        expect(indexes.next()?["name"]).to(bsonEqual("_id_"))
        expect(indexes.next()?["name"]).to(bsonEqual("cat_1"))
        expect(indexes.next()?["name"]).to(bsonEqual("cat_-1"))
        expect(indexes.next()).to(beNil())
    }

    func testCreateIndexFromKeys() throws {
        expect(try self.coll.createIndex(["cat": 1])).to(equal("cat_1"))

        let indexOptions = IndexOptions(name: "blah", unique: true)
        let model = IndexModel(keys: ["cat": -1], options: indexOptions)
        expect(try self.coll.createIndex(model)).to(equal("blah"))

        let indexes = try coll.listIndexes()
        expect(indexes.next()?["name"]).to(bsonEqual("_id_"))
        expect(indexes.next()?["name"]).to(bsonEqual("cat_1"))

        let thirdIndex = indexes.next()
        expect(thirdIndex?["name"]).to(bsonEqual("blah"))
        expect(thirdIndex?["unique"]).to(bsonEqual(true))

        expect(indexes.next()).to(beNil())
    }

    func testDropIndexByName() throws {
        let model = IndexModel(keys: ["cat": 1])
        expect(try self.coll.createIndex(model)).to(equal("cat_1"))
        expect(try self.coll.dropIndex("cat_1")).toNot(throwError())

        // now there should only be _id_ left
        let indexes = try coll.listIndexes()
        expect(indexes.next()?["name"]).to(bsonEqual("_id_"))
        expect(indexes.next()).to(beNil())
    }

    func testDropIndexByModel() throws {
        let model = IndexModel(keys: ["cat": 1])
        expect(try self.coll.createIndex(model)).to(equal("cat_1"))

        let res = try self.coll.dropIndex(model)
        expect((res["ok"] as? BSONNumber)?.doubleValue).to(bsonEqual(1.0))

        // now there should only be _id_ left
        let indexes = try coll.listIndexes()
        expect(indexes).toNot(beNil())
        expect(indexes.next()?["name"]).to(bsonEqual("_id_"))
        expect(indexes.next()).to(beNil())
    }

    func testDropIndexByKeys() throws {
        let model = IndexModel(keys: ["cat": 1])
        expect(try self.coll.createIndex(model)).to(equal("cat_1"))

        let res = try self.coll.dropIndex(["cat": 1])
        expect((res["ok"] as? BSONNumber)?.doubleValue).to(bsonEqual(1.0))

        // now there should only be _id_ left
        let indexes = try coll.listIndexes()
        expect(indexes).toNot(beNil())
        expect(indexes.next()?["name"]).to(bsonEqual("_id_"))
        expect(indexes.next()).to(beNil())
    }

    func testDropAllIndexes() throws {
        let model = IndexModel(keys: ["cat": 1])
        expect(try self.coll.createIndex(model)).to(equal("cat_1"))

        let res = try self.coll.dropIndexes()
        expect((res["ok"] as? BSONNumber)?.doubleValue).to(bsonEqual(1.0))

        // now there should only be _id_ left
        let indexes = try coll.listIndexes()
        expect(indexes.next()?["name"]).to(bsonEqual("_id_"))
        expect(indexes.next()).to(beNil())
    }

    func testListIndexes() throws {
        let indexes = try self.coll.listIndexes()
        // New collection, so expect just the _id_ index to exist.
        expect(indexes.next()?["name"]).to(bsonEqual("_id_"))
        expect(indexes.next()).to(beNil())
    }

    func testCreateDropIndexByModelWithMaxTimeMS() throws {
        let center = NotificationCenter.default
        let maxTimeMS: Int64 = 1000

        let client = try MongoClient.makeTestClient(options: ClientOptions(commandMonitoring: true))
        let db = client.db(type(of: self).testDatabase)

        let collection = db.collection("collection")
        try collection.insertOne(["test": "blahblah"])

        var receivedEvents = [CommandStartedEvent]()
        let observer = center.addObserver(forName: nil, object: nil, queue: nil) { notif in
            guard let event = notif.userInfo?["event"] as? CommandStartedEvent else {
                return
            }
            receivedEvents.append(event)
        }

        defer { center.removeObserver(observer) }

        let model = IndexModel(keys: ["cat": 1])
        let wc = try WriteConcern(w: .number(1))
        let createIndexOpts = CreateIndexOptions(writeConcern: wc, maxTimeMS: maxTimeMS)
        expect( try collection.createIndex(model, options: createIndexOpts)).to(equal("cat_1"))

        let dropIndexOpts = DropIndexOptions(writeConcern: wc, maxTimeMS: maxTimeMS)
        let res = try collection.dropIndex(model, options: dropIndexOpts)
        expect((res["ok"] as? BSONNumber)?.doubleValue).to(bsonEqual(1.0))

        // now there should only be _id_ left
        let indexes = try coll.listIndexes()
        expect(indexes).toNot(beNil())
        expect(indexes.next()?["name"]).to(bsonEqual("_id_"))
        expect(indexes.next()).to(beNil())

        // test that maxTimeMS is an accepted option for createIndex and dropIndex
        expect(receivedEvents.count).to(equal(2))
        expect(receivedEvents[0].command["createIndexes"]).toNot(beNil())
        expect(receivedEvents[0].command["maxTimeMS"]).toNot(beNil())
        expect(receivedEvents[0].command["maxTimeMS"]).to(bsonEqual(maxTimeMS))
        expect(receivedEvents[1].command["dropIndexes"]).toNot(beNil())
        expect(receivedEvents[1].command["maxTimeMS"]).toNot(beNil())
        expect(receivedEvents[1].command["maxTimeMS"]).to(bsonEqual(maxTimeMS))
    }
}

extension IndexOptions: Equatable {
    public static func == (lhs: IndexOptions, rhs: IndexOptions) -> Bool {
        return lhs.background == rhs.background &&
            lhs.expireAfterSeconds == rhs.expireAfterSeconds &&
            lhs.name == rhs.name &&
            lhs.sparse == rhs.sparse &&
            lhs.storageEngine == rhs.storageEngine &&
            lhs.unique == rhs.unique &&
            lhs.indexVersion == rhs.indexVersion &&
            lhs.defaultLanguage == rhs.defaultLanguage &&
            lhs.languageOverride == rhs.languageOverride &&
            lhs.textIndexVersion == rhs.textIndexVersion &&
            lhs.weights == rhs.weights &&
            lhs.sphereIndexVersion == rhs.sphereIndexVersion &&
            lhs.bits == rhs.bits &&
            lhs.max == rhs.max &&
            lhs.min == rhs.min &&
            lhs.bucketSize == rhs.bucketSize &&
            lhs.partialFilterExpression == rhs.partialFilterExpression &&
            lhs.collation?["locale"] as? String == rhs.collation?["locale"] as? String
            // ^ server adds a bunch of extra fields and a version number
            // to collations. rather than deal with those, just verify the
            // locale matches.
    }
}
