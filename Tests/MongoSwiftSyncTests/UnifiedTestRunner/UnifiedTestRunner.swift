import MongoSwiftSync
import Nimble
import TestsCommon

struct UnifiedTestRunner {
    enum InternalClient {
        /// For all topologies besides sharded, we use a single client.
        case single(MongoClient)
        /// For sharded topologies, we often need to target commands to particular mongoses, so we use a separate
        /// client for each host we're connecting to.
        case mongosClients([ServerAddress: MongoClient])

        /// Returns an internal client; for usage in situations where any client connected to the topology will do -
        /// that is, if the topology is sharded, we do not care about targeting a particular mongos.
        var anyClient: MongoClient {
            switch self {
            case let .single(c):
                return c
            case let .mongosClients(clientMap):
                return clientMap.first!.1
            }
        }

        /// If the internal client is a map of per-mongos clients, returns that map; otherwise throws an erorr.
        func asMongosClients() throws -> [ServerAddress: MongoClient] {
            guard case let .mongosClients(clientMap) = self else {
                throw TestError(
                    message: "Runner unexpectedly did not create per-mongos clients"
                )
            }
            return clientMap
        }
    }

    let internalClient: InternalClient
    let serverVersion: ServerVersion
    let topologyType: TestTopologyConfiguration
    let serverParameters: BSONDocument

    static let minSchemaVersion = SchemaVersion(rawValue: "1.0.0")!
    static let maxSchemaVersion = SchemaVersion(rawValue: "1.5.0")!

    init() throws {
        switch MongoSwiftTestCase.topologyType {
        case .sharded:
            var mongosClients = [ServerAddress: MongoClient]()
            for host in MongoSwiftTestCase.getHosts() {
                let connString = MongoSwiftTestCase.getConnectionString(forHost: host)
                let client = try MongoClient.makeTestClient(connString.toString())
                mongosClients[host] = client
            }
            self.internalClient = .mongosClients(mongosClients)
        default:
            let client = try MongoClient.makeTestClient()
            self.internalClient = .single(client)
        }
        self.serverVersion = try self.internalClient.anyClient.serverVersion()
        self.topologyType = try self.internalClient.anyClient.topologyType()
        self.serverParameters = try self.internalClient.anyClient.serverParameters()
    }

    func terminateOpenTransactions() throws {
        // Using the internal MongoClient, execute the killAllSessions command on either the primary or, if
        // connected to a sharded cluster, all mongos servers.
        switch self.topologyType {
        case .single,
             .loadBalanced,
             _ where MongoSwiftTestCase.serverless:
            return
        case .replicaSet:
            // The test runner MAY ignore any command failure with error Interrupted(11601) to work around
            // SERVER-38335.
            do {
                let opts = RunCommandOptions(readPreference: .primary)
                _ = try self.internalClient.anyClient.db("admin").runCommand(["killAllSessions": []], options: opts)
            } catch let commandError as MongoError.CommandError where commandError.code == 11601 {}
        case .sharded, .shardedReplicaSet:
            for (_, client) in try self.internalClient.asMongosClients() {
                do {
                    _ = try client.db("admin").runCommand(["killAllSessions": []])
                } catch let commandError as MongoError.CommandError where commandError.code == 11601 {
                    continue
                }
            }
        }
    }

    func getUnmetRequirement(_ requirement: TestRequirement) -> UnmetRequirement? {
        requirement.getUnmetRequirement(givenCurrent: self.serverVersion, self.topologyType, self.serverParameters)
    }

    /// Runs the provided files. `skipTestCases` is a map of file description strings to arrays of test description
    /// strings indicating cases to skip. If the array contains a single string "*" all tests in the file will be
    /// skipped.
    func runFiles(_ files: [UnifiedTestFile], skipTests: [String: [String]] = [:]) throws {
        for file in files {
            // Upon loading a file, the test runner MUST read the schemaVersion field and determine if the test file
            // can be processed further.
            guard file.schemaVersion >= Self.minSchemaVersion && file.schemaVersion <= Self.maxSchemaVersion else {
                throw TestError(
                    message: "Test file \"\(file.description)\" has unsupported schema version \(file.schemaVersion)"
                )
            }

            // If runOnRequirements is specified, the test runner MUST skip the test file unless one or more
            //  runOnRequirement objects are satisfied.
            if let requirements = file.runOnRequirements {
                guard requirements.contains(where: { self.getUnmetRequirement($0) == nil }) else {
                    fileLevelLog("Skipping tests from file \"\(file.description)\", deployment requirements not met.")
                    continue
                }
            }

            let skippedTestsForFile = skipTests[file.description] ?? []
            if skippedTestsForFile == ["*"] {
                fileLevelLog("Skipping all tests from file \"\(file.description)\", was included in skip list")
                continue
            }

            for test in file.tests {
                // If test.skipReason is specified, the test runner MUST skip this test and MAY use the string value to
                // log a message.
                if let skipReason = test.skipReason {
                    fileLevelLog(
                        "Skipping test \"\(test.description)\" from file \"\(file.description)\": \(skipReason)."
                    )
                    continue
                }

                if skippedTestsForFile.contains(test.description) {
                    fileLevelLog(
                        "Skipping test \"\(test.description)\" from file \"\(file.description)\", " +
                            "was included in skip list"
                    )
                    continue
                }

                // If test.runOnRequirements is specified, the test runner MUST skip the test unless one or more
                // runOnRequirement objects are satisfied.
                if let requirements = test.runOnRequirements {
                    guard requirements.contains(where: { self.getUnmetRequirement($0) == nil }) else {
                        fileLevelLog(
                            "Skipping test \"\(test.description)\" from file \"\(file.description)\", " +
                                "deployment requirements not met."
                        )
                        continue
                    }
                }

                // If initialData is specified, for each collectionData therein the test runner MUST drop the
                // collection and insert the specified documents (if any) using a "majority" write concern. If no
                // documents are specified, the test runner MUST create the collection with a "majority" write concern.
                // The test runner MUST use the internal MongoClient for these operations.
                if let initialData = file.initialData {
                    for collData in initialData {
                        let db = self.internalClient.anyClient.db(collData.databaseName)
                        let collOpts = MongoCollectionOptions(writeConcern: .majority)
                        let coll = db.collection(collData.collectionName, options: collOpts)
                        try coll.drop()

                        guard !collData.documents.isEmpty else {
                            _ = try db.createCollection(
                                collData.collectionName,
                                options: CreateCollectionOptions(writeConcern: .majority)
                            )
                            continue
                        }

                        try coll.insertMany(collData.documents)
                    }
                }

                let context = Context(
                    path: [],
                    entities: try file.createEntities?.toEntityMap() ?? [:],
                    internalClient: self.internalClient
                )

                // Workaround for SERVER-39704:  a test runners MUST execute a non-transactional distinct command on
                // each mongos server before running any test that might execute distinct within a transaction. To ease
                // the implementation, test runners MAY execute distinct before every test.
                if self.topologyType.isSharded && !MongoSwiftTestCase.serverless {
                    let collEntities = context.entities.values.compactMap { try? $0.asCollection() }
                    for (_, client) in try self.internalClient.asMongosClients() {
                        for entity in collEntities {
                            _ = try client.db(entity.namespace.db).runCommand(
                                ["distinct": .string(entity.name), "key": "_id"]
                            )
                        }
                    }
                }

                fileLevelLog("Running test \"\(test.description)\" from file \"\(file.description)\"")

                do {
                    for (i, operation) in test.operations.enumerated() {
                        try context.withPushedElt("Operation \(i) (\(operation.name))") {
                            try operation.executeAndCheckResult(context: context)
                        }
                    }

                    var clientEvents = [String: [CommandEvent]]()
                    // If any event listeners were enabled on any client entities, the test runner MUST now disable
                    // those event listeners.
                    for (id, client) in context.entities.compactMapValues({ try? $0.asTestClient() }) {
                        clientEvents[id] = try client.stopCapturingEvents()
                    }

                    if let expectEvents = test.expectEvents {
                        // TODO: SWIFT-1321 don't skip CMAP event assertions here.
                        for expectedEventList in expectEvents where expectedEventList.eventType != .cmap {
                            let clientId = expectedEventList.client

                            guard let actualEvents = clientEvents[clientId] else {
                                throw TestError(message: "No client entity found with id \(clientId)")
                            }

                            try context.withPushedElt("Expected events for client \(clientId)") {
                                try matchesEvents(
                                    expected: expectedEventList.events,
                                    actual: actualEvents,
                                    context: context
                                )
                            }
                        }
                    }

                    if let expectedOutcome = test.outcome {
                        for collectionData in expectedOutcome {
                            let collection = self.internalClient
                                .anyClient
                                .db(collectionData.databaseName)
                                .collection(collectionData.collectionName)
                            let opts = FindOptions(
                                readConcern: .local,
                                readPreference: .primary,
                                sort: ["_id": 1]
                            )
                            let documents = try collection.find(options: opts).map { try $0.get() }

                            expect(documents.count).to(equal(collectionData.documents.count))
                            for (expected, actual) in zip(collectionData.documents, documents) {
                                expect(actual).to(
                                    sortedEqual(expected),
                                    description: "Test outcome did not match expected"
                                )
                            }
                        }
                    }
                } catch let testErr {
                    // Test runners SHOULD terminate all open transactions after each failed test by killing all
                    // sessions in the cluster.
                    do {
                        try self.terminateOpenTransactions()
                    } catch {
                        print("Failed to terminate open transactions: \(error)")
                    }
                    throw testErr
                }
            }
        }
    }
}
