import mongoc

/// A MongoDB cursor.
public class MongoCursor<T: Codable>: Sequence, IteratorProtocol {
    /// Pointer to underlying `mongoc_cursor_t`.
    internal let _cursor: OpaquePointer
    /// We store these three objects to ensure that they remain in scope for as long as this cursor does.
    private let _client: MongoClient
    private let _connection: Connection
    private let _session: ClientSession?

    private var swiftError: Error?

    /// Decoder from the `MongoCollection` or `MongoDatabase` that created this cursor.
    internal let decoder: BSONDecoder

    /**
     * Initializes a new `MongoCursor` instance. Not meant to be instantiated directly by a user.
     *
     * - Throws:
     *   - `UserError.invalidArgumentError` if the options passed to the command that generated this cursor formed an
     *     invalid combination.
     */
    internal init(client: MongoClient,
                  decoder: BSONDecoder,
                  session: ClientSession?,
                  initializer: (Connection) -> OpaquePointer) throws {
        self._connection = try session?.getConnection(forUseWith: client) ?? client.connectionPool.checkOut()
        self._cursor = initializer(self._connection)
        self._client = client
        self._session = session
        self.decoder = decoder
        self.swiftError = nil

        if let err = self.error {
            // Errors in creation of the cursor are limited to invalid argument errors, but some errors are reported
            // by libmongoc as invalid cursor errors. These would be parsed to .logicErrors, so we need to rethrow them
            // as the correct case.
            if let mongoSwiftErr = err as? MongoError {
                throw UserError.invalidArgumentError(message: mongoSwiftErr.errorDescription ?? "")
            }

            throw err
        }
    }

    /// Cleans up internal state.
    deinit {
        // If the cursor was created with a session, then the session owns the connection.
        if self._session == nil {
            self._client.connectionPool.checkIn(self._connection)
        }
        mongoc_cursor_destroy(self._cursor)
    }

    /**
     * Returns the next `Document` in this cursor or `nil`, or throws an error if one occurs -- compared to `next()`,
     * which returns `nil` and requires manually checking for an error afterward.
     * - Returns: the next `Document` in this cursor, or `nil` if at the end of the cursor
     * - Throws:
     *   - `ServerError.commandError` if an error occurs on the server while iterating the cursor.
     *   - `UserError.logicError` if this function is called after the cursor has died.
     *   - `UserError.logicError` if this function is called and the session associated with this cursor is inactive.
     *   - `DecodingError` if an error occurs decoding the server's response.
     */
    public func nextOrError() throws -> T? {
        if let next = self.next() {
            return next
        }
        if let error = self.error {
            throw error
        }
        return nil
    }

    /// The error that occurred while iterating this cursor, if one exists. This should be used to check for errors
    /// after `next()` returns `nil`.
    public var error: Error? {
        if let err = self.swiftError {
            return err
        }

        var replyPtr = UnsafeMutablePointer<BSONPointer?>.allocate(capacity: 1)
        defer {
            replyPtr.deinitialize(count: 1)
            replyPtr.deallocate()
        }

        var error = bson_error_t()
        guard mongoc_cursor_error_document(self._cursor, &error, replyPtr) else {
            return nil
        }

        // If a reply is present, it implies the error occurred on the server. This *should* always be a commandError,
        // but we will still parse the mongoc error to cover all cases.
        if let docPtr = replyPtr.pointee {
            // we have to copy because libmongoc owns the pointer.
            let reply = Document(copying: docPtr)
            return extractMongoError(error: error, reply: reply)
        }

        // Otherwise, the only feasible error is that the user tried to advance a dead cursor, which is a logic error.
        // We will still parse the mongoc error to cover all cases.
        return extractMongoError(error: error)
    }

    /// Returns the next `Document` in this cursor, or nil. Once this function returns `nil`, the caller should use
    /// the `.error` property to check for errors.
    public func next() -> T? {
        do {
            let operation = NextOperation(cursor: self)
            let out = try operation.execute(using: self._connection, session: self._session)
            self.swiftError = nil
            return out
        } catch {
            self.swiftError = error
            return nil
        }
    }
}
