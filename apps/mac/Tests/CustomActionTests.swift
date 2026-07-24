import XCTest

final class CustomActionMatcherTests: XCTestCase {
    func testNormalizationAndArgumentCaptureTable() throws {
        let action = CustomAction(
            trigger: "deploy {arg}",
            type: .shell,
            payload: "deploy {arg}"
        )
        let cases: [(String, String)] = [
            ("deploy staging", "staging"),
            ("  DEPLOY,   staging fix!! ", "staging fix"),
            ("deploy\tfeature-42", "feature 42"),
        ]

        for (transcript, expectedArgument) in cases {
            let match = try XCTUnwrap(
                CustomActionMatcher.match(
                    transcript,
                    actions: [action]
                )
            )
            XCTAssertEqual(match.action, action)
            XCTAssertEqual(match.capturedArgument, expectedArgument)
        }
    }

    func testNoArgumentTriggerRequiresExactNormalizedEquality() {
        let action = CustomAction(
            trigger: "ship it",
            type: .shortcut,
            payload: "ship"
        )

        XCTAssertNotNil(
            CustomActionMatcher.match(
                "SHIP...   IT!",
                actions: [action]
            )
        )
        XCTAssertNil(
            CustomActionMatcher.match(
                "ship it now",
                actions: [action]
            )
        )
        XCTAssertNil(
            CustomActionMatcher.match(
                "ship",
                actions: [action]
            )
        )
    }

    func testArgumentTriggerRequiresANonemptyTail() {
        let action = CustomAction(
            trigger: "deploy {arg}",
            type: .shell,
            payload: "deploy {arg}"
        )
        XCTAssertNil(
            CustomActionMatcher.match(
                "deploy",
                actions: [action]
            )
        )
    }

    func testExactActionWinsBeforeArgumentPattern() {
        let argumentAction = CustomAction(
            trigger: "deploy {arg}",
            type: .shell,
            payload: "deploy {arg}"
        )
        let exactAction = CustomAction(
            trigger: "deploy staging",
            type: .shortcut,
            payload: "deploy staging"
        )

        XCTAssertEqual(
            CustomActionMatcher.match(
                "deploy staging",
                actions: [argumentAction, exactAction]
            )?.action,
            exactAction
        )
    }

    func testInvalidPlaceholderPositionsNeverMatch() {
        let actions = [
            CustomAction(
                trigger: "{arg} deploy",
                type: .shell,
                payload: "{arg}"
            ),
            CustomAction(
                trigger: "deploy {arg} now",
                type: .shell,
                payload: "{arg}"
            ),
            CustomAction(
                trigger: "deploy {arg} {arg}",
                type: .shell,
                payload: "{arg}"
            ),
        ]

        XCTAssertNil(
            CustomActionMatcher.match(
                "deploy staging now",
                actions: actions
            )
        )
    }
}

final class CustomActionPayloadTests: XCTestCase {
    func testURLArgumentUsesRFC3986UnreservedEncoding() {
        XCTAssertEqual(
            CustomActionPayload.url(
                "https://example.com/search?q={arg}",
                argument: "C++ & café"
            ),
            "https://example.com/search?q=C%2B%2B%20%26%20caf%C3%A9"
        )
    }

    func testShellArgumentIsOneSingleQuotedWord() {
        XCTAssertEqual(
            CustomActionPayload.shell(
                "deploy --branch {arg}",
                argument: "it's; $(touch /tmp/nope)"
            ),
            "deploy --branch 'it'\\''s; $(touch /tmp/nope)'"
        )
    }

    func testRawPayloadSubstitutionPreservesArgumentText() {
        XCTAssertEqual(
            CustomActionPayload.raw(
                "hello, {arg}!",
                argument: "Andrew"
            ),
            "hello, Andrew!"
        )
    }
}

@MainActor
final class CustomActionStoreTests: XCTestCase {
    func testDuplicateNormalizedTriggerIsRejected() throws {
        let context = try temporaryStore()
        defer { context.remove() }
        let store = CustomActionStore(fileURL: context.fileURL)

        _ = try store.add(
            trigger: "Deploy!!! {arg}",
            type: .shell,
            payload: "deploy {arg}"
        )

        XCTAssertThrowsError(
            try store.add(
                trigger: "  deploy {arg} ",
                type: .shell,
                payload: "ship {arg}"
            )
        ) { error in
            XCTAssertEqual(
                error as? CustomActionValidationError,
                .duplicateTrigger
            )
        }
        XCTAssertEqual(store.actions.count, 1)
    }

    func testStorePersistsAddUpdateAndRemoveAsPrettyJSON() throws {
        let context = try temporaryStore()
        defer { context.remove() }
        var store: CustomActionStore? = CustomActionStore(
            fileURL: context.fileURL
        )

        let added = try store?.add(
            trigger: "open notes",
            type: .open,
            payload: "notes"
        )
        let action = try XCTUnwrap(added)
        try store?.update(
            CustomAction(
                id: action.id,
                trigger: "open my notes",
                type: .open,
                payload: "notes",
                alwaysAllow: false
            )
        )

        let json = try String(
            contentsOf: context.fileURL,
            encoding: .utf8
        )
        XCTAssertTrue(json.contains("\n  {"))
        XCTAssertTrue(json.contains("\"trigger\" : \"open my notes\""))

        store = nil
        let reloaded = CustomActionStore(fileURL: context.fileURL)
        XCTAssertEqual(reloaded.actions.count, 1)
        XCTAssertEqual(reloaded.actions.first?.id, action.id)
        XCTAssertEqual(reloaded.actions.first?.trigger, "open my notes")

        reloaded.remove(id: action.id)
        XCTAssertTrue(reloaded.actions.isEmpty)
        let persisted = try JSONDecoder().decode(
            [CustomAction].self,
            from: Data(contentsOf: context.fileURL)
        )
        XCTAssertTrue(persisted.isEmpty)
    }

    func testValidationRejectsMissingArgumentAndInvalidURL() throws {
        let context = try temporaryStore()
        defer { context.remove() }
        let store = CustomActionStore(fileURL: context.fileURL)

        XCTAssertThrowsError(
            try store.add(
                trigger: "search {arg}",
                type: .url,
                payload: "https://example.com/search"
            )
        ) { error in
            XCTAssertEqual(
                error as? CustomActionValidationError,
                .missingArgumentPlaceholder
            )
        }

        XCTAssertThrowsError(
            try store.add(
                trigger: "bad site",
                type: .url,
                payload: "not a url"
            )
        ) { error in
            XCTAssertEqual(
                error as? CustomActionValidationError,
                .invalidURL
            )
        }

        XCTAssertThrowsError(
            try store.add(
                trigger: "run shortcut {arg}",
                type: .shortcut,
                payload: "my shortcut"
            )
        ) { error in
            XCTAssertEqual(
                error as? CustomActionValidationError,
                .missingArgumentPlaceholder
            )
        }
    }

    func testImportRejectsNormalizedDuplicatesWithoutMutation() throws {
        let context = try temporaryStore()
        defer { context.remove() }
        let store = CustomActionStore(fileURL: context.fileURL)
        _ = try store.add(
            trigger: "keep me",
            type: .open,
            payload: "finder"
        )

        let importedURL = context.directory.appendingPathComponent(
            "import.json"
        )
        let duplicates = [
            CustomAction(
                trigger: "ship it",
                type: .shortcut,
                payload: "ship"
            ),
            CustomAction(
                trigger: "SHIP, IT!",
                type: .shortcut,
                payload: "other"
            ),
        ]
        try JSONEncoder().encode(duplicates).write(to: importedURL)

        XCTAssertThrowsError(
            try store.importJSON(from: importedURL)
        ) { error in
            XCTAssertEqual(
                error as? CustomActionValidationError,
                .duplicateTrigger
            )
        }
        XCTAssertEqual(store.actions.map(\.trigger), ["keep me"])
    }

    private func temporaryStore() throws -> (
        directory: URL,
        fileURL: URL,
        remove: () -> Void
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "andrew-dictate-actions-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (
            directory,
            directory.appendingPathComponent("actions.json"),
            {
                try? FileManager.default.removeItem(at: directory)
            }
        )
    }
}
