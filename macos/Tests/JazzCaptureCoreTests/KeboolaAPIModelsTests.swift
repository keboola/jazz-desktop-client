import XCTest

@testable import JazzCaptureCore

/// Decoding tests against fixture JSON copied from REAL response shapes: tokens/verify and
/// files/prepare captured live 2026-06-13 (values anonymized), Stream API shapes from
/// kbagent's live-tested client fixtures. If one of these breaks, the API changed — check
/// the live response before "fixing" the model.
final class KeboolaAPIModelsTests: XCTestCase {
    // MARK: tokens/verify

    func testDecodesNonMasterTokenVerify() throws {
        // Trimmed live response; unknown keys (bucketPermissions, limits, …) prove tolerance.
        let fixture = """
            {
              "id": "6664953",
              "created": "2026-06-13T00:23:59+0200",
              "description": "E2E demo",
              "isMasterToken": false,
              "canManageBuckets": true,
              "expires": null,
              "creatorToken": {"id": 6504066, "description": "petr@example.com"},
              "bucketPermissions": {"in.c-otlp-jazz": "manage"},
              "owner": {
                "id": 2968,
                "name": "Jazz",
                "type": "production",
                "region": "europe-west3",
                "features": ["queuev2"],
                "defaultBackend": "snowflake",
                "fileStorageProvider": "gcp"
              },
              "adminOwner": {"id": 36, "name": "Petr S", "email": "petr@example.com"}
            }
            """
        let verify = try JSONDecoder().decode(KeboolaAPI.TokenVerify.self, from: Data(fixture.utf8))
        XCTAssertEqual(verify.id, "6664953")
        XCTAssertEqual(verify.owner.id, 2968)
        XCTAssertEqual(verify.owner.name, "Jazz")
        XCTAssertEqual(verify.owner.fileStorageProvider, "gcp")
        XCTAssertFalse(verify.isMaster)
        XCTAssertTrue(verify.canManageBuckets == true)
        XCTAssertNil(verify.expires)
        XCTAssertEqual(verify.bucketPermissions, ["in.c-otlp-jazz": "manage"])
        // Email comes from creatorToken.description; the token's own description is not one.
        XCTAssertEqual(verify.userEmail, "petr@example.com")
    }

    func testDecodesFullScopedTokenSecurityShape() throws {
        let fixture = """
            {
              "id": "123456",
              "description": "Jazz device",
              "isMasterToken": false,
              "isExpired": false,
              "isDisabled": false,
              "canManageBuckets": false,
              "canManageTokens": false,
              "canReadAllFileUploads": false,
              "expires": "2099-07-03T12:00:00+00:00",
              "bucketPermissions": {"in.c-otlp-device-1": "write"},
              "owner": {"id": 2968, "name": "Jazz"}
            }
            """
        let verify = try JSONDecoder().decode(
            KeboolaAPI.TokenVerify.self, from: Data(fixture.utf8))

        XCTAssertEqual(verify.id, "123456")
        XCTAssertEqual(verify.isMasterToken, false)
        XCTAssertEqual(verify.isExpired, false)
        XCTAssertEqual(verify.isDisabled, false)
        XCTAssertEqual(verify.canManageBuckets, false)
        XCTAssertEqual(verify.canManageTokens, false)
        XCTAssertEqual(verify.canReadAllFileUploads, false)
        XCTAssertEqual(verify.expires, "2099-07-03T12:00:00+00:00")
        XCTAssertNotNil(verify.expiresAtDate)
        XCTAssertEqual(verify.bucketPermissions, ["in.c-otlp-device-1": "write"])
    }

    func testLegacyVerifyShapeLeavesSecurityFieldsUnknownRatherThanSafe() throws {
        let fixture = """
            {
              "id": "1",
              "description": "legacy token",
              "owner": {"id": 1, "name": "P"}
            }
            """
        let verify = try JSONDecoder().decode(
            KeboolaAPI.TokenVerify.self, from: Data(fixture.utf8))

        XCTAssertNil(verify.isMasterToken)
        XCTAssertNil(verify.isExpired)
        XCTAssertNil(verify.isDisabled)
        XCTAssertNil(verify.canManageBuckets)
        XCTAssertNil(verify.canManageTokens)
        XCTAssertNil(verify.canReadAllFileUploads)
        XCTAssertNil(verify.expires)
        XCTAssertNil(verify.bucketPermissions)
    }

    func testMasterDetectedViaAdminKeyAndEmailFromDescription() throws {
        // Admin tokens may omit isMasterToken; the `admin` key alone must flag master, and
        // the token description IS the user's email on these.
        let fixture = """
            {
              "id": "12345",
              "description": "petr@example.com",
              "owner": {"id": 2968, "name": "Jazz"},
              "admin": {"id": 36, "name": "Petr S", "role": "admin"}
            }
            """
        let verify = try JSONDecoder().decode(KeboolaAPI.TokenVerify.self, from: Data(fixture.utf8))
        XCTAssertTrue(verify.isMaster)
        XCTAssertEqual(verify.userEmail, "petr@example.com")

        // And the explicit flag alone is enough too.
        let flagged = """
            {"id": "1", "isMasterToken": true, "owner": {"id": 1, "name": "P"}}
            """
        XCTAssertTrue(
            try JSONDecoder().decode(KeboolaAPI.TokenVerify.self, from: Data(flagged.utf8)).isMaster)
    }

    func testNoEmailWhenNothingLooksLikeOne() throws {
        let fixture = """
            {
              "id": "1",
              "description": "ci token",
              "creatorToken": {"id": 2, "description": "provisioner"},
              "owner": {"id": 1, "name": "P"}
            }
            """
        let verify = try JSONDecoder().decode(KeboolaAPI.TokenVerify.self, from: Data(fixture.utf8))
        XCTAssertNil(verify.userEmail)
    }

    // MARK: files/prepare

    func testDecodesFilesPrepareWithGCSUploadParams() throws {
        // Live shape from POST /v2/storage/files/prepare with federationToken:true (GCP).
        let fixture = """
            {
              "id": 84585035,
              "created": "2026-06-13T01:08:48+0200",
              "isPublic": false,
              "isSliced": false,
              "name": "jazz_a1_shape_test.png",
              "fileType": "csv",
              "url": "https://storage.googleapis.com/some-bucket/exp-15/2968/key",
              "provider": "gcp",
              "region": "europe-west3",
              "sizeBytes": null,
              "tags": ["jazz-test"],
              "maxAgeDays": 15,
              "creatorToken": {"id": 6664953, "description": "E2E demo"},
              "gcsUploadParams": {
                "projectId": "some-gcp-project",
                "bucket": "some-staging-bucket",
                "key": "exp-15/2968/files/2026/06/13/84585035.jazz_a1_shape_test.png",
                "access_token": "fake-federation-token",
                "expires_in": 3599,
                "token_type": "Bearer"
              }
            }
            """
        let prepare = try JSONDecoder().decode(
            KeboolaAPI.FilesPrepare.self, from: Data(fixture.utf8))
        XCTAssertEqual(prepare.id, 84585035)
        XCTAssertEqual(prepare.provider, "gcp")
        XCTAssertEqual(prepare.region, "europe-west3")
        XCTAssertEqual(prepare.maxAgeDays, 15)
        let gcs = try XCTUnwrap(prepare.gcsUploadParams)
        XCTAssertEqual(gcs.accessToken, "fake-federation-token")
        XCTAssertEqual(gcs.bucket, "some-staging-bucket")
        XCTAssertEqual(gcs.key, "exp-15/2968/files/2026/06/13/84585035.jazz_a1_shape_test.png")
        XCTAssertEqual(gcs.tokenType, "Bearer")
        XCTAssertEqual(gcs.expiresIn, 3599)
    }

    func testDecodesFileListForNarrationDedup() throws {
        // Live shape from GET /v2/storage/files?tags[]=narration&tags[]=label:… — the list the
        // narration uploader scans to dedup. `url` is the signed read URL it HEAD-checks;
        // `sizeBytes` is null (the agent doesn't send it to prepare), proving we must HEAD.
        let fixture = """
            [
              {
                "id": 85269171,
                "created": "2026-06-16T12:24:57+0200",
                "isPublic": false,
                "name": "jazz_s_d84a3203_l_5be2ced9_narration.m4a",
                "url": "https://storage.googleapis.com/bkt/key?X-Goog-Algorithm=GOOG4-RSA-SHA256",
                "provider": "gcp",
                "region": "europe-west3",
                "sizeBytes": null,
                "tags": ["jazz", "session:s-d84a3203", "label:l-5be2ced9", "narration"]
              },
              {
                "id": 85269008,
                "created": "2026-06-16T12:23:01+0200",
                "name": "jazz_s_d84a3203_l_5be2ced9_narration.m4a",
                "url": "https://storage.googleapis.com/bkt/key2?X-Goog-Algorithm=GOOG4-RSA-SHA256",
                "tags": ["jazz", "label:l-5be2ced9", "narration"]
              }
            ]
            """
        let items = try JSONDecoder().decode(
            [KeboolaAPI.FileListItem].self, from: Data(fixture.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, 85269171)
        XCTAssertEqual(items[0].created, "2026-06-16T12:24:57+0200")
        XCTAssertTrue(items[0].url?.hasPrefix("https://storage.googleapis.com/") == true)
        XCTAssertEqual(items[0].tags?.contains("label:l-5be2ced9"), true)
        XCTAssertEqual(items[1].id, 85269008)
    }

    func testFilesMatchingAllTagsAndFiltersTheOrMatchedList() {
        // The Storage API ORs multiple tags, so a query for ["narration","label:X"] returns EVERY
        // narration file. AND-filtering must keep only files carrying BOTH tags — without it the
        // narration dedup matched any old clip on the shared `narration` tag, reused it, and
        // discarded the fresh recording (every workshop then processed stale audio).
        let f = { (id: Int, tags: [String]) in
            KeboolaAPI.FileListItem(id: id, name: nil, url: nil, tags: tags, created: nil)
        }
        let listed = [
            f(1, ["jazz", "label:l-OLD", "narration"]),  // different label -> exclude
            f(2, ["jazz", "label:l-WANT", "narration"]),  // the clip we actually want
            f(3, ["jazz", "label:l-WANT"]),  // right label but not narration (e.g. a screenshot)
            f(4, ["narration"]),  // narration only, no label
        ]
        XCTAssertEqual(
            KeboolaAPI.filesMatchingAllTags(listed, ["narration", "label:l-WANT"]).map(\.id), [2],
            "only the file carrying BOTH narration and label:l-WANT")
        // A brand-new label matches nothing -> empty -> caller does a fresh upload (the behaviour
        // the OR query silently broke by "finding" an unrelated clip).
        XCTAssertTrue(
            KeboolaAPI.filesMatchingAllTags(listed, ["narration", "label:l-FRESH"]).isEmpty)
        XCTAssertEqual(KeboolaAPI.filesMatchingAllTags(listed, []).count, 4)  // no requirement
        XCTAssertTrue(KeboolaAPI.filesMatchingAllTags([f(9, [])], ["narration"]).isEmpty)  // nil tags
    }

    // MARK: Stream API

    func testDecodesStreamSourceListAndEndpoint() throws {
        // Shape from kbagent's live-tested stream client fixtures (secret is fake).
        let fixture = """
            {
              "sources": [
                {
                  "sourceId": "jazz",
                  "type": "otlp",
                  "name": "jazz",
                  "description": "",
                  "otlp": {
                    "url": "https://stream-in.example.com/otlp/2968/jazz/fakeSecret123",
                    "baseUrl": "https://stream-in.example.com/otlp/2968/jazz",
                    "secret": "fakeSecret123"
                  }
                }
              ]
            }
            """
        let list = try JSONDecoder().decode(
            KeboolaAPI.StreamSourceList.self, from: Data(fixture.utf8))
        XCTAssertEqual(list.sources.count, 1)
        let source = list.sources[0]
        XCTAssertEqual(source.sourceId, "jazz")
        XCTAssertEqual(source.type, "otlp")
        // The exporter posts under THIS url (+ /v1/logs, /v1/traces) — secret included.
        XCTAssertEqual(
            source.otlpEndpoint, "https://stream-in.example.com/otlp/2968/jazz/fakeSecret123")
    }

    func testStreamTaskLifecycleShapes() throws {
        // POST /sources answers 202 with an unfinished task carrying the new sourceId.
        let accepted = """
            {"taskId": "t1", "isFinished": false, "outputs": {"sourceId": "jazz"},
             "url": "https://stream.example.com/v1/tasks/t1"}
            """
        let task = try JSONDecoder().decode(KeboolaAPI.StreamTask.self, from: Data(accepted.utf8))
        XCTAssertEqual(task.taskId, "t1")
        XCTAssertFalse(task.finished)
        XCTAssertFalse(task.failed)
        XCTAssertEqual(task.outputs?.sourceId, "jazz")
        XCTAssertEqual(task.url, "https://stream.example.com/v1/tasks/t1")

        let success = """
            {"taskId": "t1", "isFinished": true, "status": "success"}
            """
        let done = try JSONDecoder().decode(KeboolaAPI.StreamTask.self, from: Data(success.utf8))
        XCTAssertTrue(done.finished)
        XCTAssertFalse(done.failed)

        // error as a plain string…
        let failedString = """
            {"taskId": "t1", "isFinished": true, "status": "error", "error": "boom"}
            """
        let failed = try JSONDecoder().decode(
            KeboolaAPI.StreamTask.self, from: Data(failedString.utf8))
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.error, "boom")

        // …and as a nested object — both must decode (the API does not pin the shape).
        let failedObject = """
            {"taskId": "t1", "isFinished": true, "error": {"message": "nested boom"}}
            """
        let nested = try JSONDecoder().decode(
            KeboolaAPI.StreamTask.self, from: Data(failedObject.utf8))
        XCTAssertTrue(nested.failed)
        XCTAssertEqual(nested.error, "nested boom")
    }

    func testDecodesMasterTokenRequiredError() throws {
        // Live-verified 2026-06-13: a non-master token on GET /v1/branches/default/sources.
        let fixture = """
            {
              "statusCode": 401,
              "error": "stream.api.masterTokenRequired",
              "message": "Please provide a master token of a project administrator."
            }
            """
        let error = try JSONDecoder().decode(KeboolaAPI.APIError.self, from: Data(fixture.utf8))
        XCTAssertEqual(error.statusCode, 401)
        XCTAssertTrue(error.isMasterTokenRequired)

        let other = try JSONDecoder().decode(
            KeboolaAPI.APIError.self,
            from: Data(#"{"error": "accessTokenInvalid", "message": "Invalid token"}"#.utf8))
        XCTAssertFalse(other.isMasterTokenRequired)
    }
}

/// The user-pasted stream-URL hygiene used by the manual (non-master-token) onboarding.
final class StreamEndpointTests: XCTestCase {
    func testNormalizeStripsSignalPathsAndSlashes() {
        let base = "https://stream-in.europe-west3.gcp.keboola.com/otlp/123/jazz/secret"
        XCTAssertEqual(StreamEndpoint.normalize(base), base)
        XCTAssertEqual(StreamEndpoint.normalize(base + "/"), base)
        XCTAssertEqual(StreamEndpoint.normalize(base + "/v1/logs"), base)
        XCTAssertEqual(StreamEndpoint.normalize(base + "/v1/traces/"), base)
        XCTAssertEqual(StreamEndpoint.normalize("  " + base + "\n"), base)
    }

    func testNormalizeRejectsNonURLs() {
        XCTAssertNil(StreamEndpoint.normalize(""))
        XCTAssertNil(StreamEndpoint.normalize("   "))
        XCTAssertNil(StreamEndpoint.normalize("not a url"))
        XCTAssertNil(StreamEndpoint.normalize("ftp://stream.example.com/otlp/1/s/secret"))
        XCTAssertNil(StreamEndpoint.normalize("https://"))
    }
}
