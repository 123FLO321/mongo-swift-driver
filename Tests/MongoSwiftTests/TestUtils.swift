import Foundation
import mongoc
@testable import MongoSwift
import Nimble
import XCTest

typealias DeleteOneModel = MongoCollection<Document>.DeleteOneModel
typealias DeleteManyModel = MongoCollection<Document>.DeleteManyModel
typealias InsertOneModel = MongoCollection<Document>.InsertOneModel
typealias ReplaceOneModel = MongoCollection<Document>.ReplaceOneModel
typealias UpdateOneModel = MongoCollection<Document>.UpdateOneModel
typealias UpdateManyModel = MongoCollection<Document>.UpdateManyModel

// sourcery: disableTests
class MongoSwiftTestCase: XCTestCase {
    /// Gets the name of the database the test case is running against.
    internal class var testDatabase: String {
        return "test"
    }

    /// Gets the path of the directory containing spec files, depending on whether
    /// we're running from XCode or the command line
    static var specsPath: String {
        // if we can access the "/Tests" directory, assume we're running from command line
        if FileManager.default.fileExists(atPath: "./Tests") {
            return "./Tests/Specs"
        }
        // otherwise we're in Xcode, get the bundle's resource path
        guard let path = Bundle(for: self).resourcePath else {
            XCTFail("Missing resource path")
            return ""
        }
        return path
    }

    /// Gets the connection string for the database being used for testing from the environment variable, $MONGODB_URI.
    /// If the environment variable does not exist, this will use a default of "mongodb://127.0.0.1/".
    static var connStr: String {
        if let connStr = ProcessInfo.processInfo.environment["MONGODB_URI"] {
            if self.topologyType == .sharded {
                guard let uri = mongoc_uri_new(connStr) else {
                    return connStr
                }

                defer {
                    mongoc_uri_destroy(uri)
                }

                guard let hosts = mongoc_uri_get_hosts(uri) else {
                    return connStr
                }

                let hostAndPort = withUnsafeBytes(of: hosts.pointee.host_and_port) { rawPtr -> String in
                    let ptr = rawPtr.baseAddress!.assumingMemoryBound(to: CChar.self)
                    return String(cString: ptr)
                }

                return "mongodb://\(hostAndPort)/"
            }

            return connStr
        }

        return "mongodb://127.0.0.1/"
    }

    /// Indicates that we are running the tests with SSL enabled, determined by the environment variable $SSL.
    static var ssl: Bool {
        return ProcessInfo.processInfo.environment["SSL"] == "ssl"
    }

    /// Returns the path where the SSL key file is located, determined by the environment variable $SSL_PEM_FILE.
    static var sslKeyFilePath: String? {
        guard self.ssl else { return nil }
        return ProcessInfo.processInfo.environment["SSL_KEY_FILE"]
    }

    /// Returns the path where the SSL CA file is located, determined by the environment variable $SSL_CA_FILE..
    static var sslCAFilePath: String? {
        guard self.ssl else { return nil }
        return ProcessInfo.processInfo.environment["SSL_CA_FILE"]
    }

    // indicates whether we are running on a 32-bit platform
    static let is32Bit = Int.bsonType == .int32

    /// Generates a unique collection name of the format "<Test Suite>_<Test Name>_<suffix>". If no suffix is provided,
    /// the last underscore is omitted.
    internal func getCollectionName(suffix: String? = nil) -> String {
        var name = self.name.replacingOccurrences(of: "[\\[\\]-]", with: "", options: [.regularExpression])
        if let suf = suffix {
            name += "_" + suf
        }
        return name.replacingOccurrences(of: "[ \\+\\$]", with: "_", options: [.regularExpression])
    }

    static var topologyType: TopologyDescription.TopologyType {
        guard let topology = ProcessInfo.processInfo.environment["MONGODB_TOPOLOGY"] else {
            return .single
        }
        return TopologyDescription.TopologyType(from: topology)
    }
}

extension MongoClient {
    internal func serverVersion() throws -> ServerVersion {
        let buildInfo = try self.db("admin").runCommand(["buildInfo": 1],
                                                        options: RunCommandOptions(
                                                            readPreference: ReadPreference(.primary)
                                                        ))
        guard let versionString = buildInfo["version"] as? String else {
            throw TestError(message: "buildInfo reply missing version string: \(buildInfo)")
        }
        return try ServerVersion(versionString)
    }

    internal func serverVersionIsInRange(_ min: String?, _ max: String?) throws -> Bool {
        let version = try self.serverVersion()

        if let min = min, version < (try ServerVersion(min)) {
            return false
        }
        if let max = max, version > (try ServerVersion(max)) {
            return false
        }

        return true
    }

    internal convenience init(options: ClientOptions? = nil) throws {
        var uri = MongoSwiftTestCase.connStr
        if MongoSwiftTestCase.ssl {
            guard let keyFilePath = MongoSwiftTestCase.sslKeyFilePath,
                let caFilePath = MongoSwiftTestCase.sslCAFilePath else {
                throw TestError(message: "SSL enabled, but missing path to key file and/or ca file")
            }
            try self.connectionPool.setSSLOpts(keyFile: keyFilePath, caFile: caFilePath)
        }

        try self.init(uri, options: options)
    }
}

extension Document {
    internal func sortedEquals(_ other: Document) -> Bool {
        let keys = self.keys.sorted()
        let otherKeys = other.keys.sorted()

        // first compare keys, because rearrangeDoc will discard any that don't exist in `expected`
        expect(keys).to(equal(otherKeys))

        let rearranged = rearrangeDoc(other, toLookLike: self)
        return self == rearranged
    }

    init(fromJSONFile file: URL) throws {
        let jsonString = try String(contentsOf: file, encoding: .utf8)
        try self.init(fromJSON: jsonString)
    }
}

/// Cleans and normalizes a given JSON string for comparison purposes
func clean(json: String?) -> String {
    guard let str = json else {
        return ""
    }
    do {
        let doc = try Document(fromJSON: str.data(using: .utf8)!)
        return doc.extendedJSON
    } catch {
        print("Failed to clean string: \(str)")
        return String()
    }
}

// Adds a custom "cleanEqual" predicate that compares two JSON strings for equality after normalizing
// them with the "clean" function
internal func cleanEqual(_ expectedValue: String?) -> Predicate<String> {
    return Predicate.define("cleanEqual <\(stringify(expectedValue))>") { actualExpression, msg in
        let actualValue = try actualExpression.evaluate()
        let matches = clean(json: actualValue) == clean(json: expectedValue) && expectedValue != nil
        if expectedValue == nil || actualValue == nil {
            if expectedValue == nil && actualValue != nil {
                return PredicateResult(
                    status: .fail,
                    message: msg.appendedBeNilHint()
                )
            }
            return PredicateResult(status: .fail, message: msg)
        }
        return PredicateResult(status: PredicateStatus(bool: matches), message: msg)
    }
}

// Adds a custom "sortedEqual" predicate that compares two `Document`s and returns true if they
// have the same key/value pairs in them
internal func sortedEqual(_ expectedValue: Document?) -> Predicate<Document> {
    return Predicate.define("sortedEqual <\(stringify(expectedValue))>") { actualExpression, msg in
        let actualValue = try actualExpression.evaluate()

        guard let expected = expectedValue, let actual = actualValue else {
            if expectedValue == nil && actualValue != nil {
                return PredicateResult(
                    status: .fail,
                    message: msg.appendedBeNilHint()
                )
            }
            return PredicateResult(status: .fail, message: msg)
        }

        let matches = expected.sortedEquals(actual)
        return PredicateResult(status: PredicateStatus(bool: matches), message: msg)
    }
}

/// Given two documents, returns a copy of the input document with all keys that *don't*
/// exist in `standard` removed, and with all matching keys put in the same order they
/// appear in `standard`.
internal func rearrangeDoc(_ input: Document, toLookLike standard: Document) -> Document {
    var output = Document()
    for (k, v) in standard {
        // if it's a document, recursively rearrange to look like corresponding sub-document
        if let sDoc = v as? Document, let iDoc = input[k] as? Document {
            output[k] = rearrangeDoc(iDoc, toLookLike: sDoc)

        // if it's an array, recursively rearrange to look like corresponding sub-array
        } else if let sArr = v as? [Document], let iArr = input[k] as? [Document] {
            var newArr = [Document]()
            for (i, el) in iArr.enumerated() {
                newArr.append(rearrangeDoc(el, toLookLike: sArr[i]))
            }
            output[k] = newArr
        // just copy the value over as is
        } else {
            output[k] = input[k]
        }
    }
    return output
}

/// A Nimble matcher for testing BSONValue equality.
internal func bsonEqual(_ expectedValue: BSONValue?) -> Predicate<BSONValue> {
    return Predicate.define("equal <\(stringify(expectedValue))>") { actualExpression, msg in
        let actualValue = try actualExpression.evaluate()
        switch (expectedValue, actualValue) {
        case (nil, _?):
            return PredicateResult(status: .fail, message: msg.appendedBeNilHint())
        case (nil, nil), (_, nil):
            return PredicateResult(status: .fail, message: msg)
        case let (expected?, actual?):
            let matches = expected.bsonEquals(actual)
            return PredicateResult(bool: matches, message: msg)
        }
    }
}
