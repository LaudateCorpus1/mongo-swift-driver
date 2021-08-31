import MongoSwiftSync
import Nimble
import TestsCommon
import XCTest

private var _client: MongoSwiftSync.MongoClient?

final class MongoCollectionTests: MongoSwiftTestCase {
    var collName: String = ""
    var coll: MongoSwiftSync.MongoCollection<BSONDocument>!
    let doc1: BSONDocument = ["_id": 1, "cat": "dog"]
    let doc2: BSONDocument = ["_id": 2, "cat": "cat"]

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
            self.coll = try client.db(Self.testDatabase).createCollection(self.collName)
            try self.coll.insertMany([self.doc1, self.doc2])
        } catch {
            XCTFail("Setup failed: \(error)")
        }
    }

    /// Teardown a single test - run after each testX function
    override func tearDown() {
        super.tearDown()
        do {
            if self.coll != nil { try self.coll.drop() }
        } catch {
            XCTFail("Dropping test collection \(Self.testDatabase).\(self.collName) failed: \(error)")
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

    func testCount() throws {
        expect(try self.coll.countDocuments()).to(equal(2))
        let options = CountDocumentsOptions(limit: 5, maxTimeMS: 1000, skip: 5)
        expect(try self.coll.countDocuments(options: options)).to(equal(0))
    }

    func testInsertOne() throws {
        expect(try self.coll.deleteMany([:])).toNot(beNil())
        expect(try self.coll.insertOne(self.doc1)?.insertedID).to(equal(1))
        expect(try self.coll.insertOne(self.doc2)?.insertedID).to(equal(2))
        expect(try self.coll.countDocuments()).to(equal(2))

        // try inserting a document without an ID
        let docNoID: BSONDocument = ["x": 1]
        // verify that an _id is returned in the InsertOneResult
        expect(try self.coll.insertOne(docNoID)?.insertedID).toNot(beNil())
        // verify that the original document was not modified
        expect(docNoID).to(equal(["x": 1]))

        // error code 11000: DuplicateKey
        let expectedError = MongoError.WriteError.new(
            writeFailure: MongoError.WriteFailure.new(code: 11000, codeName: "DuplicateKey", message: ""),
            writeConcernFailure: nil,
            errorLabels: nil
        )

        expect(try self.coll.insertOne(["_id": 1])).to(throwError(expectedError))
    }

    func testInsertOneWithUnacknowledgedWriteConcern() throws {
        let options = InsertOneOptions(writeConcern: try WriteConcern(w: .number(0)))
        let insertOneResult = try self.coll.insertOne(["x": 1], options: options)
        expect(insertOneResult).to(beNil())
    }

    func testAggregate() throws {
        expect(try self.coll.aggregate([["$project": ["_id": 0, "cat": 1]]]).all())
            .to(equal([["cat": "dog"], ["cat": "cat"]] as [BSONDocument]))
    }

    func testGenericAggregate() throws {
        // Format that is incompatible with the format of the original documents,
        // it is only compatible with the ones that come back from the aggregate
        struct AggregationFormat: Codable, Equatable {
            var bird: String
        }
        let result = try self.coll.aggregate(
            [["$project": ["_id": 0, "bird": "$cat"]]],
            withOutputType: AggregationFormat.self
        ).all()
        let expected = [AggregationFormat(bird: "dog"), AggregationFormat(bird: "cat")]
        expect(result).to(equal(expected))
    }

    func testGenericAggregateBadFormat() throws {
        // Format that is incompatible with the format of the original documents,
        // and is incompatible with the what aggregate returns
        struct AggregationFormat: Codable, Equatable {
            var bird: String
        }
        expect(try self.coll.aggregate(
            [["$project": ["_id": 0, "cat": 1]]],
            withOutputType: AggregationFormat.self
        ).all()).to(throwError(errorType: DecodingError.self))
    }

    func testDrop() throws {
        let encoder = BSONEncoder()

        let client = try MongoClient.makeTestClient()
        let monitor = client.addCommandMonitor()

        let db = client.db(Self.testDatabase)

        let collection = db.collection("collection")
        try collection.insertOne(["test": "blahblah"])

        let expectedWriteConcern: WriteConcern = try WriteConcern(journal: true, w: .number(1))

        try monitor.captureEvents {
            let opts = DropCollectionOptions(writeConcern: expectedWriteConcern)
            expect(try collection.drop(options: opts)).toNot(throwError())
        }

        let event = monitor.commandStartedEvents().first
        expect(event).toNot(beNil())
        expect(event?.command["drop"]).toNot(beNil())
        expect(event?.command["writeConcern"]).toNot(beNil())
        expect(event?.command["writeConcern"]?.documentValue).to(sortedEqual(try? encoder.encode(expectedWriteConcern)))
    }

    func testInsertMany() throws {
        expect(try self.coll.countDocuments()).to(equal(2))
        // try inserting a mix of documents with and without IDs to verify they are generated
        let docNoId1: BSONDocument = ["x": 1]
        let docNoId2: BSONDocument = ["x": 2]
        let docId1: BSONDocument = ["_id": 10, "x": 8]
        let docId2: BSONDocument = ["_id": 11, "x": 9]

        let res = try coll.insertMany([docNoId1, docNoId2, docId1, docId2])

        // the inserted IDs should either be the ones we set,
        // or newly created BSONObjectIDs
        for (_, v) in res!.insertedIDs {
            if let val = v.toInt() {
                expect([10, 11]).to(contain(val))
            } else {
                expect(v.type).to(equal(.objectID))
            }
        }

        // verify that docs without _ids were not modified.
        expect(docNoId1).to(equal(["x": 1]))
        expect(docNoId2).to(equal(["x": 2]))

        let newDoc1: BSONDocument = ["_id": .objectID()]
        let newDoc2: BSONDocument = ["_id": .objectID()]
        let newDoc3: BSONDocument = ["_id": .objectID()]
        let newDoc4: BSONDocument = ["_id": .objectID()]

        let expectedResultOrdered = BulkWriteResult.new(insertedCount: 1, insertedIDs: [0: newDoc1["_id"]!])
        let expectedErrorsOrdered = [
            MongoError.BulkWriteFailure.new(code: 11000, codeName: "DuplicateKey", message: "", index: 1)
        ]

        let expectedErrorOrdered = MongoError.BulkWriteError.new(
            writeFailures: expectedErrorsOrdered,
            writeConcernFailure: nil,
            otherError: nil,
            result: expectedResultOrdered,
            errorLabels: nil
        )

        expect(try self.coll.insertMany([newDoc1, docId1, newDoc2, docId2])).to(throwError(expectedErrorOrdered))

        let expectedErrors = [
            MongoError.BulkWriteFailure.new(code: 11000, codeName: "DuplicateKey", message: "", index: 1),
            MongoError.BulkWriteFailure.new(code: 11000, codeName: "DuplicateKey", message: "", index: 3)
        ]
        let expectedResult = BulkWriteResult.new(
            insertedCount: 2,
            insertedIDs: [0: newDoc3["_id"]!, 2: newDoc4["_id"]!]
        )
        let expectedError = MongoError.BulkWriteError.new(
            writeFailures: expectedErrors,
            writeConcernFailure: nil,
            otherError: nil,
            result: expectedResult,
            errorLabels: nil
        )

        let options = InsertManyOptions(ordered: false)
        expect(try self.coll.insertMany([newDoc3, docId1, newDoc4, docId2], options: options))
            .to(throwError(expectedError))
    }

    func testInsertManyWithEmptyValues() {
        expect(try self.coll.insertMany([])).to(throwError(errorType: MongoError.InvalidArgumentError.self))
    }

    func testInsertManyWithUnacknowledgedWriteConcern() throws {
        let options = InsertManyOptions(writeConcern: try WriteConcern(w: .number(0)))
        let insertManyResult = try self.coll.insertMany([["x": 1], ["x": 2]], options: options)
        expect(insertManyResult).to(beNil())
    }

    func testFind() throws {
        let findResult = try coll.find(["cat": "cat"])
        expect(try findResult.next()?.get()).to(equal(["_id": 2, "cat": "cat"]))
        expect(try findResult.next()?.get()).to(beNil())
    }

    func testFindOne() throws {
        let findOneResult = try self.coll.findOne(["cat": "dog"])
        expect(findOneResult).to(equal(["_id": 1, "cat": "dog"]))
    }

    func testFindOneMultipleMatches() throws {
        let findOneOptions = FindOneOptions(sort: ["_id": 1])
        let findOneResult = try self.coll.findOne(options: findOneOptions)
        expect(findOneResult).to(equal(["_id": 1, "cat": "dog"]))
    }

    func testFindOneNoMatch() throws {
        let findOneResult = try self.coll.findOne(["dog": "cat"])
        expect(findOneResult).to(beNil())
    }

    func testDeleteOne() throws {
        expect(try self.coll.deleteOne(["cat": "cat"])?.deletedCount).to(equal(1))
    }

    func testDeleteOneWithHint() throws {
        try withTestNamespace { client, _, collection in
            let requirements = TestRequirement(
                minServerVersion: ServerVersion(major: 4, minor: 4)
            )
            let unmetRequirement = try client.getUnmetRequirement(requirements)
            guard unmetRequirement == nil else {
                printSkipMessage(testName: self.name, unmetRequirement: unmetRequirement!)
                return
            }

            let doc1: BSONDocument = ["_id": 1, "cat": "meow", "dog": "bark"]
            let doc2: BSONDocument = ["_id": 2, "cat": "nya", "dog": "woof"]
            try collection.insertMany([doc1, doc2])

            let model = IndexModel(keys: ["cat": 1, "dog": 1])
            expect(try collection.createIndex(model)).to(equal("cat_1_dog_1"))

            let opts1 = DeleteOptions(hint: ["cat": 1, "dog": 1])
            let opts2 = DeleteOptions(hint: "cat_1_dog_1")
            expect(try collection.deleteOne(["cat": "meow"], options: opts1)?.deletedCount).to(equal(1))
            expect(try collection.deleteOne(["cat": "nya"], options: opts2)?.deletedCount).to(equal(1))

            let invalidOpts1 = DeleteOptions(hint: ["nonexistant_index": 1])
            let invalidOpts2 = DeleteOptions(hint: "nonexistant_index")
            expect(try collection.deleteOne([:], options: invalidOpts1))
                .to(throwError(errorType: MongoError.WriteError.self))
            expect(try collection.deleteOne([:], options: invalidOpts2))
                .to(throwError(errorType: MongoError.WriteError.self))
        }
    }

    func testDeleteOneWithUnacknowledgedWriteConcern() throws {
        let options = DeleteOptions(writeConcern: try WriteConcern(w: .number(0)))
        let deleteOneResult = try self.coll.deleteOne(["cat": "cat"], options: options)
        expect(deleteOneResult).to(beNil())
    }

    func testDeleteMany() throws {
        expect(try self.coll.deleteMany([:])?.deletedCount).to(equal(2))
    }

    func testDeleteManyWithHint() throws {
        try withTestNamespace { client, _, collection in
            let requirements = TestRequirement(
                minServerVersion: ServerVersion(major: 4, minor: 4)
            )
            let unmetRequirement = try client.getUnmetRequirement(requirements)
            guard unmetRequirement == nil else {
                printSkipMessage(testName: self.name, unmetRequirement: unmetRequirement!)
                return
            }

            let doc1: BSONDocument = ["_id": 1, "cat": "meow", "dog": "bark"]
            let doc2: BSONDocument = ["_id": 2, "cat": "nya", "dog": "woof"]
            try collection.insertMany([doc1, doc2])

            let model = IndexModel(keys: ["cat": 1, "dog": 1])
            expect(try collection.createIndex(model)).to(equal("cat_1_dog_1"))

            let opts1 = DeleteOptions(hint: ["cat": 1, "dog": 1])
            let opts2 = DeleteOptions(hint: "cat_1_dog_1")
            expect(try collection.deleteMany([:], options: opts1)?.deletedCount).to(equal(2))
            try collection.insertMany([doc1, doc2])
            expect(try collection.deleteMany([:], options: opts2)?.deletedCount).to(equal(2))

            let invalidOpts1 = DeleteOptions(hint: ["nonexistant_index": 1])
            let invalidOpts2 = DeleteOptions(hint: "nonexistant_index")
            expect(try collection.deleteMany([:], options: invalidOpts1))
                .to(throwError(errorType: MongoError.WriteError.self))
            expect(try collection.deleteMany([:], options: invalidOpts2))
                .to(throwError(errorType: MongoError.WriteError.self))
        }
    }

    func testDeleteManyWithUnacknowledgedWriteConcern() throws {
        let options = DeleteOptions(writeConcern: try WriteConcern(w: .number(0)))
        let deleteManyResult = try self.coll.deleteMany([:], options: options)
        expect(deleteManyResult).to(beNil())
    }

    func testRenamed() throws {
        guard MongoSwiftTestCase.topologyType != .sharded else {
            print("Skipping test case \(self.name) because renameCollection is not compatible with sharded collections")
            return
        }

        try self.withTestNamespace { client, db, coll in
            let encoder = BSONEncoder()
            let to = self.getCollectionName(suffix: "renamed")
            let expectedWriteConcern = try WriteConcern(journal: true, w: .number(1))

            // insert before rename
            try coll.insertMany([["doc1": "test1"], ["doc2": "test2"], ["doc1": "test3"]])

            let monitor = client.addCommandMonitor()
            try monitor.captureEvents {
                let opts = RenameCollectionOptions(writeConcern: expectedWriteConcern)
                expect(try coll.renamed(to: to, options: opts)).toNot(throwError())
            }

            // ensure a collection with the new name exists with the documents
            expect(try db.collection(to).countDocuments()).to(equal(3))

            // the old collection should be empty
            expect(try coll.countDocuments()).to(equal(0))

            let event = monitor.commandStartedEvents().first
            expect(event).toNot(beNil())
            expect(event?.command["renameCollection"]).toNot(beNil())
            expect(event?.command["writeConcern"]?.documentValue)
                .to(sortedEqual(try? encoder.encode(expectedWriteConcern)))
        }
    }

    func testRenamedWithDropTarget() throws {
        guard MongoSwiftTestCase.topologyType != .sharded else {
            print("Skipping test case \(self.name) because renameCollection is not compatible with sharded collections")
            return
        }
        try self.withTestNamespace { _, db, coll in
            let to = self.getCollectionName(suffix: "exists")
            let existingColl = try db.createCollection(to)
            try existingColl.insertMany([["doc1": "test1"], ["doc2": "test2"], ["doc1": "test3"]])

            let opts1 = RenameCollectionOptions(dropTarget: true)
            // renaming with an existing collection name but dropTarget set to true should not throw an error
            expect(try coll.renamed(to: to, options: opts1)).toNot(throwError())

            // the existing collection should be dropped at this point
            expect(try existingColl.countDocuments()).to(equal(0))

            let collName2 = self.getCollectionName(suffix: "coll2")
            let coll2 = try db.createCollection(collName2)
            let opts2 = RenameCollectionOptions(dropTarget: false)
            // test with drop target set to false and new collection name to existing collection throws an error
            expect(try coll2.renamed(to: to, options: opts2)).to(throwError(errorType: MongoError.CommandError.self))
        }
    }

    func testReplaceOne() throws {
        let replaceOneResult = try coll.replaceOne(filter: ["_id": 1], replacement: ["apple": "banana"])
        expect(replaceOneResult?.matchedCount).to(equal(1))
        expect(replaceOneResult?.modifiedCount).to(equal(1))
    }

    func testReplaceOneWithHint() throws {
        try withTestNamespace { client, _, collection in
            let requirements = TestRequirement(
                minServerVersion: ServerVersion(major: 4, minor: 2)
            )
            let unmetRequirement = try client.getUnmetRequirement(requirements)
            guard unmetRequirement == nil else {
                printSkipMessage(testName: self.name, unmetRequirement: unmetRequirement!)
                return
            }

            let doc1: BSONDocument = ["_id": 1, "cat": "meow", "dog": "bark"]
            let doc2: BSONDocument = ["_id": 2, "cat": "nya", "dog": "woof"]
            try collection.insertMany([doc1, doc2])

            let model = IndexModel(keys: ["cat": 1, "dog": 1])
            expect(try collection.createIndex(model)).to(equal("cat_1_dog_1"))

            let opts1 = ReplaceOptions(hint: ["cat": 1, "dog": 1])
            let opts2 = ReplaceOptions(hint: "cat_1_dog_1")
            let result1 = try collection.replaceOne(filter: ["_id": 1], replacement: ["cat": "mew"], options: opts1)
            expect(result1?.matchedCount).to(equal(1))
            expect(result1?.modifiedCount).to(equal(1))
            let result2 = try collection.replaceOne(filter: ["_id": 2], replacement: ["cat": "pss"], options: opts2)
            expect(result2?.matchedCount).to(equal(1))
            expect(result2?.modifiedCount).to(equal(1))

            let invalidOpts1 = ReplaceOptions(hint: ["nonexistant_index": 1])
            let invalidOpts2 = ReplaceOptions(hint: "nonexistant_index")
            expect(try collection.replaceOne(filter: [:], replacement: [:], options: invalidOpts1))
                .to(throwError(errorType: MongoError.WriteError.self))
            expect(try collection.replaceOne(filter: [:], replacement: [:], options: invalidOpts2))
                .to(throwError(errorType: MongoError.WriteError.self))
        }
    }

    func testReplaceOneWithUnacknowledgedWriteConcern() throws {
        let options = ReplaceOptions(writeConcern: try WriteConcern(w: .number(0)))
        let replaceOneResult = try coll.replaceOne(
            filter: ["_id": 1], replacement: ["apple": "banana"], options: options
        )
        expect(replaceOneResult).to(beNil())
    }

    func testUpdateOne() throws {
        let updateOneResult = try coll.updateOne(
            filter: ["_id": 2], update: ["$set": ["apple": "banana"]]
        )
        expect(updateOneResult?.matchedCount).to(equal(1))
        expect(updateOneResult?.modifiedCount).to(equal(1))
    }

    func testUpdateOneWithHint() throws {
        try withTestNamespace { client, _, collection in
            let requirements = TestRequirement(
                minServerVersion: ServerVersion(major: 4, minor: 2)
            )
            let unmetRequirement = try client.getUnmetRequirement(requirements)
            guard unmetRequirement == nil else {
                printSkipMessage(testName: self.name, unmetRequirement: unmetRequirement!)
                return
            }

            let doc1: BSONDocument = ["_id": 1, "cat": "meow", "dog": "bark"]
            let doc2: BSONDocument = ["_id": 2, "cat": "nya", "dog": "woof"]
            try collection.insertMany([doc1, doc2])

            let model = IndexModel(keys: ["cat": 1, "dog": 1])
            expect(try collection.createIndex(model)).to(equal("cat_1_dog_1"))

            let opts1 = UpdateOptions(hint: ["cat": 1, "dog": 1])
            let opts2 = UpdateOptions(hint: "cat_1_dog_1")
            let result1 = try collection.updateOne(filter: ["_id": 1], update: ["$set": ["cat": "mew"]], options: opts1)
            expect(result1?.matchedCount).to(equal(1))
            expect(result1?.modifiedCount).to(equal(1))
            let result2 = try collection.updateOne(filter: ["_id": 2], update: ["$set": ["cat": "pss"]], options: opts2)
            expect(result2?.matchedCount).to(equal(1))
            expect(result2?.modifiedCount).to(equal(1))

            let invalidOpts1 = UpdateOptions(hint: ["nonexistant_index": 1])
            let invalidOpts2 = UpdateOptions(hint: "nonexistant_index")
            expect(try collection.updateOne(filter: [:], update: [:], options: invalidOpts1))
                .to(throwError(errorType: MongoError.WriteError.self))
            expect(try collection.updateOne(filter: [:], update: [:], options: invalidOpts2))
                .to(throwError(errorType: MongoError.WriteError.self))
        }
    }

    func testUpdateOneWithUnacknowledgedWriteConcern() throws {
        let options = UpdateOptions(writeConcern: try WriteConcern(w: .number(0)))
        let updateOneResult = try coll.updateOne(
            filter: ["_id": 2], update: ["$set": ["apple": "banana"]], options: options
        )
        expect(updateOneResult).to(beNil())
    }

    func testUpdateMany() throws {
        let updateManyResult = try coll.updateMany(
            filter: [:], update: ["$set": ["apple": "pear"]]
        )
        expect(updateManyResult?.matchedCount).to(equal(2))
        expect(updateManyResult?.modifiedCount).to(equal(2))
    }

    func testUpdateManyWithHint() throws {
        try withTestNamespace { client, _, collection in
            let requirements = TestRequirement(
                minServerVersion: ServerVersion(major: 4, minor: 2)
            )
            let unmetRequirement = try client.getUnmetRequirement(requirements)
            guard unmetRequirement == nil else {
                printSkipMessage(testName: self.name, unmetRequirement: unmetRequirement!)
                return
            }

            let doc1: BSONDocument = ["_id": 1, "cat": "meow", "dog": "bark"]
            let doc2: BSONDocument = ["_id": 2, "cat": "nya", "dog": "woof"]
            try collection.insertMany([doc1, doc2])

            let model = IndexModel(keys: ["cat": 1, "dog": 1])
            expect(try collection.createIndex(model)).to(equal("cat_1_dog_1"))

            let opts1 = UpdateOptions(hint: ["cat": 1, "dog": 1])
            let opts2 = UpdateOptions(hint: "cat_1_dog_1")
            let result1 = try collection.updateMany(
                filter: ["_id": 1],
                update: ["$set": ["cat": "mew"]],
                options: opts1
            )
            expect(result1?.matchedCount).to(equal(1))
            expect(result1?.modifiedCount).to(equal(1))
            let result2 = try collection.updateMany(
                filter: ["_id": 2],
                update: ["$set": ["cat": "pss"]],
                options: opts2
            )
            expect(result2?.matchedCount).to(equal(1))
            expect(result2?.modifiedCount).to(equal(1))

            let invalidOpts1 = UpdateOptions(hint: ["nonexistant_index": 1])
            let invalidOpts2 = UpdateOptions(hint: "nonexistant_index")
            expect(try collection.updateMany(filter: [:], update: [:], options: invalidOpts1))
                .to(throwError(errorType: MongoError.WriteError.self))
            expect(try collection.updateMany(filter: [:], update: [:], options: invalidOpts2))
                .to(throwError(errorType: MongoError.WriteError.self))
        }
    }

    func testUpdateManyWithUnacknowledgedWriteConcern() throws {
        let options = UpdateOptions(writeConcern: try WriteConcern(w: .number(0)))
        let updateManyResult = try coll.updateMany(
            filter: [:], update: ["$set": ["apple": "pear"]], options: options
        )
        expect(updateManyResult).to(beNil())
    }

    func testUpdateAndReplaceWithHintPreviousVersion() throws {
        try withTestNamespace { client, _, collection in
            let requirements = TestRequirement(
                maxServerVersion: ServerVersion(major: 4, minor: 2)
            )
            let unmetRequirement = try client.getUnmetRequirement(requirements)
            guard unmetRequirement == nil else {
                printSkipMessage(testName: self.name, unmetRequirement: unmetRequirement!)
                return
            }

            let doc1: BSONDocument = ["_id": 1, "cat": "meow", "dog": "bark"]
            let doc2: BSONDocument = ["_id": 2, "cat": "nya", "dog": "woof"]
            try collection.insertMany([doc1, doc2])

            let model = IndexModel(keys: ["cat": 1, "dog": 1])
            expect(try collection.createIndex(model)).to(equal("cat_1_dog_1"))

            let replaceOp1 = ReplaceOptions(hint: ["cat": 1, "dog": 1])
            let replaceOp2 = ReplaceOptions(hint: "cat_1_dog_1")
            let updateOp1 = UpdateOptions(hint: ["cat": 1, "dog": 1])
            let updateOp2 = UpdateOptions(hint: "cat_1_dog_1")
            expect(try collection.replaceOne(filter: [:], replacement: [:], options: replaceOp1))
                .to(throwError(errorType: MongoError.CommandError.self))
            expect(try collection.replaceOne(filter: [:], replacement: [:], options: replaceOp2))
                .to(throwError(errorType: MongoError.CommandError.self))
            expect(try collection.updateOne(filter: [:], update: [:], options: updateOp1))
                .to(throwError(errorType: MongoError.CommandError.self))
            expect(try collection.updateOne(filter: [:], update: [:], options: updateOp2))
                .to(throwError(errorType: MongoError.CommandError.self))
            expect(try collection.updateMany(filter: [:], update: [:], options: updateOp1))
                .to(throwError(errorType: MongoError.CommandError.self))
            expect(try collection.updateMany(filter: [:], update: [:], options: updateOp2))
                .to(throwError(errorType: MongoError.CommandError.self))
        }
    }

    func testDistinct() throws {
        let distinct1 = try coll.distinct(fieldName: "cat", filter: [:])
        expect(BSON.array(distinct1).arrayValue?.compactMap(\.stringValue).sorted()).to(equal(["cat", "dog"]))
        // nonexistent field
        expect(try self.coll.distinct(fieldName: "abc", filter: [:])).to(beEmpty())

        // test a null distinct value
        try self.coll.insertOne(["cat": .null])
        let distinct2 = try coll.distinct(fieldName: "cat", filter: [:])
        expect(distinct2).to(haveCount(3))
        // swiftlint:disable trailing_closure
        expect(distinct2).to(containElementSatisfying({ $0 == .null }))
        // swiftlint:enable trailing_closure
    }

    func testGetName() {
        expect(self.coll.name).to(equal(self.collName))
    }

    func testCursorIteration() throws {
        let findResult1 = try coll.find(["cat": "cat"])
        while let _ = try findResult1.next()?.get() {}

        let findResult2 = try coll.find(["cat": "cat"])
        for _ in findResult2 {}
    }

    struct Basic: Codable, Equatable {
        let x: Int
        let y: String
    }

    func testCodableCollection() throws {
        let client = try MongoClient.makeTestClient()
        let db = client.db(Self.testDatabase)
        let coll1 = try db.createCollection(self.getCollectionName(suffix: "codable"), withType: Basic.self)
        defer { try? coll1.drop() }

        let b1 = Basic(x: 1, y: "hi")
        let b2 = Basic(x: 2, y: "hello")
        let b3 = Basic(x: 3, y: "blah")
        let b4 = Basic(x: 4, y: "hi")
        let b5 = Basic(x: 5, y: "abc")

        try coll1.insertOne(b1)
        try coll1.insertMany([b2, b3])
        try coll1.replaceOne(filter: ["x": 2], replacement: b4)
        expect(try coll1.countDocuments()).to(equal(3))

        for doc in try coll1.find().all() {
            expect(doc).to(beAnInstanceOf(Basic.self))
        }

        // find one and replace w/ collection type replacement
        expect(try coll1.findOneAndReplace(filter: ["x": 1], replacement: b5)).to(equal(b1))

        // test successfully decode to collection type
        expect(try coll1.findOneAndUpdate(filter: ["x": 3], update: ["$set": ["x": 6]])).to(equal(b3))
        expect(try coll1.findOneAndDelete(["x": 4])).to(equal(b4))
    }

    func testCursorType() throws {
        let encoder = BSONEncoder()

        var nonTailable = FindOptions(cursorType: .nonTailable)
        expect(try encoder.encode(nonTailable)).to(equal(["awaitData": false, "tailable": false]))

        // test mutated cursorType
        nonTailable.cursorType = .tailable
        expect(try encoder.encode(nonTailable)).to(equal(["awaitData": false, "tailable": true]))

        var tailable = FindOptions(cursorType: .tailable)
        expect(try encoder.encode(tailable)).to(equal(["awaitData": false, "tailable": true]))

        tailable.cursorType = .nonTailable
        expect(try encoder.encode(tailable)).to(equal(["awaitData": false, "tailable": false]))

        var tailableAwait = FindOptions(cursorType: .tailableAwait)
        expect(try encoder.encode(tailableAwait)).to(equal(["awaitData": true, "tailable": true]))

        tailableAwait.cursorType = .tailable
        expect(try encoder.encode(tailableAwait)).to(equal(["awaitData": false, "tailable": true]))

        // test nill cursorType
        tailableAwait.cursorType = nil
        expect(try encoder.encode(tailableAwait)).to(beNil())

        var nilTailable = FindOptions(cursorType: nil)
        expect(try encoder.encode(nilTailable)).to(beNil())

        nilTailable.cursorType = .tailable
        expect(try encoder.encode(nilTailable)).to(equal(["awaitData": false, "tailable": true]))

        nilTailable.cursorType = nil
        expect(try encoder.encode(nilTailable)).to(beNil())

        nilTailable.cursorType = .tailableAwait
        expect(try encoder.encode(nilTailable)).to(equal(["awaitData": true, "tailable": true]))
    }

    func testEncodeHint() throws {
        let encoder = BSONEncoder()

        let stringHint = AggregateOptions(hint: .indexName("hi"))
        expect(try encoder.encode(stringHint)).to(equal(["hint": "hi"]))

        let docHint = AggregateOptions(hint: .indexSpec(["hi": 1]))
        expect(try encoder.encode(docHint)).to(equal(["hint": ["hi": 1]]))
    }

    func testFindOneAndDelete() throws {
        // test using maxTimeMS
        let opts1 = FindOneAndDeleteOptions(maxTimeMS: 1000)
        let result1 = try self.coll.findOneAndDelete(["cat": "cat"], options: opts1)
        expect(result1).to(equal(self.doc2))
        expect(try self.coll.countDocuments()).to(equal(1))

        // test using a write concern
        let opts2 = FindOneAndDeleteOptions(writeConcern: .majority)
        let result2 = try self.coll.findOneAndDelete([:], options: opts2)
        expect(result2).to(equal(self.doc1))
        expect(try self.coll.countDocuments()).to(equal(0))

        // test invalid maxTimeMS throws error
        let invalidOpts1 = FindOneAndDeleteOptions(maxTimeMS: 0)
        let invalidOpts2 = FindOneAndDeleteOptions(maxTimeMS: -1)
        expect(try self.coll.findOneAndDelete([:], options: invalidOpts1))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
        expect(try self.coll.findOneAndDelete([:], options: invalidOpts2))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
    }

    func testFindOneAndReplace() throws {
        // test using maxTimeMS
        let opts1 = FindOneAndReplaceOptions(maxTimeMS: 1000)
        let result1 = try self.coll.findOneAndReplace(
            filter: ["cat": "cat"],
            replacement: ["cat": "blah"],
            options: opts1
        )
        expect(result1).to(equal(self.doc2))
        expect(try self.coll.countDocuments()).to(equal(2))

        // test using bypassDocumentValidation
        let opts2 = FindOneAndReplaceOptions(bypassDocumentValidation: true)
        let result2 = try self.coll.findOneAndReplace(
            filter: ["cat": "dog"],
            replacement: ["cat": "hi"],
            options: opts2
        )
        expect(result2).to(equal(self.doc1))
        expect(try self.coll.countDocuments()).to(equal(2))

        // test using a write concern
        let opts3 = FindOneAndReplaceOptions(writeConcern: .majority)
        let result3 = try self.coll.findOneAndReplace(
            filter: ["cat": "blah"],
            replacement: ["cat": "cat"],
            options: opts3
        )
        expect(result3).to(equal(["_id": 2, "cat": "blah"]))
        expect(try self.coll.countDocuments()).to(equal(2))

        // test invalid maxTimeMS throws error
        let invalidOpts1 = FindOneAndReplaceOptions(maxTimeMS: 0)
        let invalidOpts2 = FindOneAndReplaceOptions(maxTimeMS: -1)
        expect(try self.coll.findOneAndReplace(filter: [:], replacement: [:], options: invalidOpts1))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
        expect(try self.coll.findOneAndReplace(filter: [:], replacement: [:], options: invalidOpts2))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
    }

    func testFindOneAndUpdate() throws {
        // test using maxTimeMS
        let opts1 = FindOneAndUpdateOptions(maxTimeMS: 1000)
        let result1 = try self.coll.findOneAndUpdate(
            filter: ["cat": "cat"],
            update: ["$set": ["cat": "blah"]],
            options: opts1
        )
        expect(result1).to(equal(self.doc2))
        expect(try self.coll.countDocuments()).to(equal(2))

        // test using bypassDocumentValidation
        let opts2 = FindOneAndUpdateOptions(bypassDocumentValidation: true)
        let result2 = try self.coll.findOneAndUpdate(
            filter: ["cat": "dog"],
            update: ["$set": ["cat": "hi"]],
            options: opts2
        )
        expect(result2).to(equal(self.doc1))
        expect(try self.coll.countDocuments()).to(equal(2))

        // test using a write concern
        let opts3 = FindOneAndUpdateOptions(writeConcern: .majority)
        let result3 = try self.coll.findOneAndUpdate(
            filter: ["cat": "blah"],
            update: ["$set": ["cat": "cat"]],
            options: opts3
        )
        expect(result3).to(equal(["_id": 2, "cat": "blah"]))
        expect(try self.coll.countDocuments()).to(equal(2))

        // test invalid maxTimeMS throws error
        let invalidOpts1 = FindOneAndUpdateOptions(maxTimeMS: 0)
        let invalidOpts2 = FindOneAndUpdateOptions(maxTimeMS: -1)
        expect(try self.coll.findOneAndUpdate(filter: [:], update: [:], options: invalidOpts1))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
        expect(try self.coll.findOneAndUpdate(filter: [:], update: [:], options: invalidOpts2))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
    }

    func testFindAndModifyWithHintInPreviousVersion() throws {
        try withTestNamespace { client, _, collection in
            let requirements = TestRequirement(
                maxServerVersion: ServerVersion(major: 4, minor: 2)
            )
            let unmetRequirement = try client.getUnmetRequirement(requirements)
            guard unmetRequirement == nil else {
                printSkipMessage(testName: self.name, unmetRequirement: unmetRequirement!)
                return
            }

            let doc1: BSONDocument = ["_id": 1, "cat": "meow", "dog": "bark"]
            let doc2: BSONDocument = ["_id": 2, "cat": "nya", "dog": "woof"]
            try collection.insertMany([doc1, doc2])

            let model = IndexModel(keys: ["cat": 1, "dog": 1])
            expect(try collection.createIndex(model)).to(equal("cat_1_dog_1"))

            // Drivers must raise an error for servers < 4.2.
            let opts1 = FindOneAndReplaceOptions(hint: ["cat": 1, "dog": 1])
            let opts2 = FindOneAndReplaceOptions(hint: "cat_1_dog_1")
            let opts3 = FindOneAndUpdateOptions(hint: ["cat": 1, "dog": 1])
            let opts4 = FindOneAndUpdateOptions(hint: "cat_1_dog_1")
            let opts5 = FindOneAndDeleteOptions(hint: ["cat": 1, "dog": 1])
            let opts6 = FindOneAndDeleteOptions(hint: "cat_1_dog_1")
            expect(try collection.findOneAndReplace(filter: [:], replacement: [:], options: opts1))
                .to(throwError(errorType: MongoError.CompatibilityError.self))
            expect(try collection.findOneAndReplace(filter: [:], replacement: [:], options: opts2))
                .to(throwError(errorType: MongoError.CompatibilityError.self))
            expect(try collection.findOneAndUpdate(filter: [:], update: [:], options: opts3))
                .to(throwError(errorType: MongoError.CompatibilityError.self))
            expect(try collection.findOneAndUpdate(filter: [:], update: [:], options: opts4))
                .to(throwError(errorType: MongoError.CompatibilityError.self))
            expect(try collection.findOneAndDelete([:], options: opts5))
                .to(throwError(errorType: MongoError.CompatibilityError.self))
            expect(try collection.findOneAndDelete([:], options: opts6))
                .to(throwError(errorType: MongoError.CompatibilityError.self))
        }
    }

    func testFindAndModifyWithHint() throws {
        try withTestNamespace { client, _, collection in
            let requirements = TestRequirement(
                minServerVersion: ServerVersion(major: 4, minor: 4)
            )
            let unmetRequirement = try client.getUnmetRequirement(requirements)
            guard unmetRequirement == nil else {
                printSkipMessage(testName: self.name, unmetRequirement: unmetRequirement!)
                return
            }

            let doc1: BSONDocument = ["_id": 1, "cat": "meow", "dog": "bark"]
            let doc2: BSONDocument = ["_id": 2, "cat": "nya", "dog": "woof"]
            try collection.insertMany([doc1, doc2])

            let model = IndexModel(keys: ["cat": 1, "dog": 1])
            expect(try collection.createIndex(model)).to(equal("cat_1_dog_1"))

            // find and replace
            let opts1 = FindOneAndReplaceOptions(hint: ["cat": 1, "dog": 1])
            let result1 = try collection.findOneAndReplace(
                filter: ["cat": "meow"],
                replacement: ["cat": "hello", "dog": "bark"],
                options: opts1
            )
            expect(result1).to(equal(["_id": 1, "cat": "meow", "dog": "bark"]))
            expect(try collection.countDocuments()).to(equal(2))

            let opts2 = FindOneAndReplaceOptions(hint: "cat_1_dog_1")
            let result2 = try collection.findOneAndReplace(
                filter: ["cat": "hello"],
                replacement: ["cat": "meow", "dog": "bark"],
                options: opts2
            )
            expect(result2).to(equal(["_id": 1, "cat": "hello", "dog": "bark"]))
            expect(try collection.countDocuments()).to(equal(2))

            // find and update
            let opts3 = FindOneAndUpdateOptions(hint: ["cat": 1, "dog": 1])
            let result3 = try collection.findOneAndUpdate(
                filter: ["cat": "meow"],
                update: ["$set": ["cat": "woof", "dog": "bark"]],
                options: opts3
            )
            expect(result3).to(equal(["_id": 1, "cat": "meow", "dog": "bark"]))
            expect(try collection.countDocuments()).to(equal(2))

            let opts4 = FindOneAndUpdateOptions(hint: "cat_1_dog_1")
            let result4 = try collection.findOneAndUpdate(
                filter: ["cat": "woof"],
                update: ["$set": ["cat": "wow", "dog": "bark"]],
                options: opts4
            )
            expect(result4).to(equal(["_id": 1, "cat": "woof", "dog": "bark"]))
            expect(try collection.countDocuments()).to(equal(2))

            let opts5 = FindOneAndDeleteOptions(hint: ["cat": 1, "dog": 1])
            let result5 = try collection.findOneAndDelete(["cat": "wow"], options: opts5)
            expect(result5).to(equal(["_id": 1, "cat": "wow", "dog": "bark"]))
            expect(try collection.countDocuments()).to(equal(1))

            let opts6 = FindOneAndDeleteOptions(hint: "cat_1_dog_1")
            let result6 = try collection.findOneAndDelete(["cat": "nya"], options: opts6)
            expect(result6).to(equal(["_id": 2, "cat": "nya", "dog": "woof"]))
            expect(try collection.countDocuments()).to(equal(0))

            // test invalid hint throws error
            let invalidOpts1 = FindOneAndReplaceOptions(hint: ["nonexistant_index": 1])
            let invalidOpts2 = FindOneAndReplaceOptions(hint: "nonexistant_index")
            let invalidOpts3 = FindOneAndUpdateOptions(hint: ["nonexistant_index": 1])
            let invalidOpts4 = FindOneAndUpdateOptions(hint: "nonexistant_index")
            let invalidOpts5 = FindOneAndDeleteOptions(hint: ["nonexistant_index": 1])
            let invalidOpts6 = FindOneAndDeleteOptions(hint: "nonexistant_index")
            expect(try collection.findOneAndReplace(filter: [:], replacement: [:], options: invalidOpts1))
                .to(throwError(errorType: MongoError.CommandError.self))
            expect(try collection.findOneAndReplace(filter: [:], replacement: [:], options: invalidOpts2))
                .to(throwError(errorType: MongoError.CommandError.self))
            expect(try collection.findOneAndUpdate(filter: [:], update: [:], options: invalidOpts3))
                .to(throwError(errorType: MongoError.CommandError.self))
            expect(try collection.findOneAndUpdate(filter: [:], update: [:], options: invalidOpts4))
                .to(throwError(errorType: MongoError.CommandError.self))
            expect(try collection.findOneAndDelete([:], options: invalidOpts5))
                .to(throwError(errorType: MongoError.CommandError.self))
            expect(try collection.findOneAndDelete([:], options: invalidOpts6))
                .to(throwError(errorType: MongoError.CommandError.self))
        }
    }

    func testNullIds() throws {
        let result1 = try self.coll.insertOne(["_id": .null, "hi": "hello"])
        expect(result1).toNot(beNil())
        expect(result1?.insertedID).to(equal(.null))

        try self.coll.deleteOne(["_id": .null])

        let result2 = try self.coll.insertMany([["_id": .null], ["_id": 20]])
        expect(result2).toNot(beNil())
        expect(result2?.insertedIDs[0]).to(equal(.null))
        expect(result2?.insertedIDs[1]).to(equal(20))
    }

    func testNSNotFoundSuppression() throws {
        let client = try MongoClient.makeTestClient()
        let collection = client.db(Self.testDatabase).collection(self.getCollectionName())
        expect(try collection.drop()).toNot(throwError())
        expect(try collection.drop()).toNot(throwError())
        expect(try collection.dropIndex("ljasdfjlkasdjf")).toNot(throwError())
    }

    func testFindOneKillsCursor() throws {
        struct Blah: Codable {
            let ljadsflkjasdf: String // won't be present in result doc
        }
        try self.withTestNamespace { _, db, coll in
            try coll.insertOne([:])

            let codableColl = db.collection(coll.name, withType: Blah.self)
            _ = try? codableColl.findOne([:])
            // if the underlying cursor is leaked, this will crash in debug mode
        }
    }
}
