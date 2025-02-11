import mongoc

/// Options to use when dropping an index from a `MongoCollection`.
public struct DropIndexOptions: Encodable {
    /// An optional `WriteConcern` to use for the command.
    public var writeConcern: WriteConcern?

    /// The maximum amount of time to allow the query to run - enforced server-side.
    public var maxTimeMS: Int64?

    /// Initializer allowing any/all parameters to be omitted.
    public init(writeConcern: WriteConcern? = nil, maxTimeMS: Int64? = nil) {
        self.writeConcern = writeConcern
        self.maxTimeMS = maxTimeMS
    }
}

/// An operation corresponding to a "dropIndexes" command.
internal struct DropIndexesOperation<T: Codable>: Operation {
    private let collection: MongoCollection<T>
    private let index: BSONValue
    private let options: DropIndexOptions?

    internal init(collection: MongoCollection<T>, index: BSONValue, options: DropIndexOptions?) {
        self.collection = collection
        self.index = index
        self.options = options
    }

    internal func execute(using connection: Connection, session: ClientSession?) throws -> Document {
        let command: Document = ["dropIndexes": self.collection.name, "index": self.index]
        let opts = try encodeOptions(options: self.options, session: session)
        var reply = Document()
        var error = bson_error_t()
        let success = withMutableBSONPointer(to: &reply) { replyPtr in
            self.collection.withMongocCollection(from: connection) { collPtr in
                mongoc_collection_write_command_with_opts(collPtr, command._bson, opts?._bson, replyPtr, &error)
            }
        }
        guard success else {
            throw extractMongoError(error: error, reply: reply)
        }

        return reply
    }
}
