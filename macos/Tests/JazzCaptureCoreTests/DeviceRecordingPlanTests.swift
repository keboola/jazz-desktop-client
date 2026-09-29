import Foundation
import XCTest

@testable import JazzCaptureCore

/// The recording-plan DECISION surface: route derivation, request headers, tolerant decoding,
/// response binding and the picker's process choices. No networking and no Keychain.
final class DeviceRecordingPlanTests: XCTestCase {
    // MARK: - Route

    func testRouteReplacesOnlyTheTerminalResource() throws {
        let route = try JazzDeviceRecordingPlanRoute(routeBinding: try signedRoute())
        XCTAssertEqual(route.url.absoluteString, "https://jazz.example/api/device/recording-plan")
        XCTAssertEqual(route.deviceId, "mac-1")
        XCTAssertEqual(route.companyId, "acme")
    }

    func testRoutePreservesADeploymentPathPrefix() throws {
        let route = try JazzDeviceRecordingPlanRoute(
            routeBinding: try signedRoute(
                ingestEndpoint: "https://hub.example/apps/jazz-1234/api/archive-ingests"))
        XCTAssertEqual(
            route.url.absoluteString,
            "https://hub.example/apps/jazz-1234/api/device/recording-plan")
    }

    func testRouteMatchesAPercentEncodedArchiveResourceLikeTheEnrollmentDoes() throws {
        let route = try JazzDeviceRecordingPlanRoute(
            routeBinding: try signedRoute(
                ingestEndpoint: "https://hub.example/apps/jazz-1234/api/%61rchive-ingests"))
        XCTAssertEqual(
            route.url.absoluteString,
            "https://hub.example/apps/jazz-1234/api/device/recording-plan")
    }

    func testRouteRefusesAnEndpointThatIsNotTheArchiveResource() {
        XCTAssertNil(
            JazzDeviceRecordingPlanRoute.deploymentPrefix(ofEncodedPath: "/api/archive-ingestsx"))
        XCTAssertNil(
            JazzDeviceRecordingPlanRoute.deploymentPrefix(ofEncodedPath: "/xapi/archive-ingests"))
        XCTAssertEqual(
            JazzDeviceRecordingPlanRoute.deploymentPrefix(ofEncodedPath: "/api/archive-ingests"),
            "")
    }

    func testRouteAcceptsTheAdminHandoffEnrollmentLikeArchiveIntents() throws {
        let mvp = try JazzArchiveUploadRouteBinding(
            mvpIngestEndpoint: "https://jazz.example/api/archive-ingests",
            stackURL: "https://connection.example.keboola.com",
            projectId: "123",
            tokenId: "456",
            scope: try JazzArchiveUploadScope(
                companyId: "acme", areaId: "finance", deviceId: "mac-1"))
        let route = try JazzDeviceRecordingPlanRoute(routeBinding: mvp)
        XCTAssertEqual(route.url.absoluteString, "https://jazz.example/api/device/recording-plan")
    }

    func testRequestCarriesTheCredentialInHeadersNeverInTheURL() throws {
        let route = try JazzDeviceRecordingPlanRoute(routeBinding: try signedRoute())
        let request = route.request(
            credential: try JazzArchiveScopedDeviceCredential("123-scoped-device-secret"))

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-StorageApi-Token"),
            "123-scoped-device-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Jazz-Device-Id"), "mac-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertFalse(
            try XCTUnwrap(request.url?.absoluteString).contains("123-scoped-device-secret"))
    }

    // MARK: - Decoding

    func testDecodesTheFullContractAndIgnoresUnknownFields() throws {
        let plan = try XCTUnwrap(JazzDeviceRecordingPlan.parse(data: Data(Self.fullPlan.utf8)))

        XCTAssertEqual(plan.schemaVersion, 1)
        XCTAssertEqual(plan.deviceId, "mac-1")
        XCTAssertEqual(plan.companyId, "acme")
        XCTAssertEqual(plan.area?.areaId, "finance")
        XCTAssertEqual(plan.area?.name, "Finance")
        XCTAssertEqual(plan.areas.map(\.areaId), ["finance", "sales"])
        XCTAssertEqual(plan.areas[1].declaredProcesses.map(\.processId), ["quote"])
        XCTAssertEqual(
            plan.declaredProcesses.map(\.processId), ["refund-handling", "invoice-approval"])
        XCTAssertEqual(plan.declaredProcesses[0].description, "Customer refunds")
        XCTAssertNil(plan.declaredProcesses[1].description)
        XCTAssertEqual(plan.person?.personId, "per-1")
        XCTAssertEqual(plan.person?.displayName, "Jana")
        XCTAssertEqual(plan.bindingState, .confirmed)
        XCTAssertEqual(plan.assigned.count, 1)
        XCTAssertEqual(plan.assigned[0].assignmentId, "asg-1")
        XCTAssertEqual(plan.assigned[0].processLabel, "Refund handling")
        XCTAssertEqual(plan.assigned[0].state, "open")
        XCTAssertEqual(plan.minClientVersion, "0.27.0")
    }

    func testDecodesTheWaveZeroShapeWithNullsAndEmptyLists() throws {
        let json = """
            {"schemaVersion":1,"deviceId":"mac-1","companyId":"acme",
             "area":{"areaId":"finance","name":"Finance"},"areas":[],
             "declaredProcesses":[{"processId":"refund-handling","name":"Refund handling"}],
             "person":null,"bindingState":"unbound","assigned":[],"minClientVersion":null}
            """
        let plan = try XCTUnwrap(JazzDeviceRecordingPlan.parse(data: Data(json.utf8)))
        XCTAssertNil(plan.person)
        XCTAssertNil(plan.minClientVersion)
        XCTAssertEqual(plan.bindingState, .unbound)
        XCTAssertEqual(
            plan.processChoices(forAreaId: "finance"),
            [ProcessChoice(id: "refund-handling", name: "Refund handling")])
    }

    func testMalformedEntriesAreSkippedAndAnUnknownBindingStateDoesNotFailThePlan() throws {
        let json = """
            {"schemaVersion":1,"deviceId":"mac-1","companyId":"acme",
             "area":{"areaId":"finance","name":"Finance"},
             "declaredProcesses":[
               {"processId":"refund-handling","name":"Refund handling"},
               {"processId":"","name":"No id"},
               {"name":"Missing id"},
               42,
               {"processId":"invoice-approval","name":"Invoice approval"}],
             "assigned":[{"state":"open"},{"assignmentId":"asg-2","areaId":"finance",
               "processId":"invoice-approval","state":"open"}],
             "bindingState":"something-new"}
            """
        let plan = try XCTUnwrap(JazzDeviceRecordingPlan.parse(data: Data(json.utf8)))
        XCTAssertEqual(
            plan.declaredProcesses.map(\.processId), ["refund-handling", "invoice-approval"])
        XCTAssertEqual(plan.assigned.map(\.assignmentId), ["asg-2"])
        XCTAssertEqual(plan.bindingState, .unknown)
        XCTAssertEqual(plan.areas, [])
    }

    func testRejectsAnotherSchemaVersionOrAPlanWithoutIdentity() {
        XCTAssertNil(
            JazzDeviceRecordingPlan.parse(
                data: Data(#"{"schemaVersion":2,"deviceId":"mac-1","companyId":"acme"}"#.utf8)))
        XCTAssertNil(
            JazzDeviceRecordingPlan.parse(
                data: Data(#"{"schemaVersion":1,"companyId":"acme"}"#.utf8)))
        XCTAssertNil(JazzDeviceRecordingPlan.parse(data: Data("[]".utf8)))
        XCTAssertNil(JazzDeviceRecordingPlan.parse(data: Data("not json".utf8)))
    }

    // MARK: - Binding

    func testAPlanForAnotherDeviceOrCompanyIsRejected() throws {
        let route = try JazzDeviceRecordingPlanRoute(routeBinding: try signedRoute())
        let own = try XCTUnwrap(JazzDeviceRecordingPlan.parse(data: Data(Self.fullPlan.utf8)))
        XCTAssertNoThrow(try own.validate(for: route))

        for (device, company) in [("mac-2", "acme"), ("mac-1", "globex")] {
            let json = #"{"schemaVersion":1,"deviceId":"\#(device)","companyId":"\#(company)"}"#
            let other = try XCTUnwrap(JazzDeviceRecordingPlan.parse(data: Data(json.utf8)))
            XCTAssertThrowsError(try other.validate(for: route)) {
                XCTAssertEqual($0 as? JazzDeviceRecordingPlanError, .invalidResponse)
            }
        }
    }

    // MARK: - Picker choices

    func testTheEnrolledAreaUsesTheTopLevelInventoryInDeclarationOrder() throws {
        let plan = try XCTUnwrap(JazzDeviceRecordingPlan.parse(data: Data(Self.fullPlan.utf8)))
        XCTAssertEqual(
            plan.processChoices(forAreaId: "finance"),
            [
                ProcessChoice(id: "refund-handling", name: "Refund handling"),
                ProcessChoice(id: "invoice-approval", name: "Invoice approval"),
            ])
    }

    func testAnotherListedAreaUsesItsOwnInventory() throws {
        let plan = try XCTUnwrap(JazzDeviceRecordingPlan.parse(data: Data(Self.fullPlan.utf8)))
        XCTAssertEqual(
            plan.processChoices(forAreaId: "sales"),
            [ProcessChoice(id: "quote", name: "Quote")])
    }

    func testAnAreaThePlanDoesNotCoverIsNilSoTheCallerFallsBack() throws {
        let plan = try XCTUnwrap(JazzDeviceRecordingPlan.parse(data: Data(Self.fullPlan.utf8)))
        XCTAssertNil(plan.processChoices(forAreaId: "hr"))
        XCTAssertNil(plan.processChoices(forAreaId: ""))
    }

    func testTheEnrolledAreaWithNoDeclaredProcessesIsExploreModeNotAFallback() throws {
        let json = """
            {"schemaVersion":1,"deviceId":"mac-1","companyId":"acme",
             "area":{"areaId":"finance","name":"Finance"},"areas":[],"declaredProcesses":[]}
            """
        let plan = try XCTUnwrap(JazzDeviceRecordingPlan.parse(data: Data(json.utf8)))
        XCTAssertEqual(plan.processChoices(forAreaId: "finance"), [])
    }

    func testAnEmptyEnrolledInventoryWinsOverADisagreeingAreasEntry() throws {
        let json = """
            {"schemaVersion":1,"deviceId":"mac-1","companyId":"acme",
             "area":{"areaId":"finance","name":"Finance"},
             "areas":[{"areaId":"finance","name":"Finance",
                       "declaredProcesses":[{"processId":"invoice","name":"Invoice"}]}],
             "declaredProcesses":[]}
            """
        let plan = try XCTUnwrap(JazzDeviceRecordingPlan.parse(data: Data(json.utf8)))
        XCTAssertEqual(plan.processChoices(forAreaId: "finance"), [])
    }

    func testDuplicateProcessIdsAreOfferedOnce() throws {
        let json = """
            {"schemaVersion":1,"deviceId":"mac-1","companyId":"acme",
             "area":{"areaId":"finance","name":"Finance"},
             "declaredProcesses":[
               {"processId":"refund-handling","name":"Refund handling"},
               {"processId":"refund-handling","name":"Refund handling (dup)"}]}
            """
        let plan = try XCTUnwrap(JazzDeviceRecordingPlan.parse(data: Data(json.utf8)))
        XCTAssertEqual(
            plan.processChoices(forAreaId: "finance"),
            [ProcessChoice(id: "refund-handling", name: "Refund handling")])
    }

    // MARK: - Fixtures

    static let fullPlan = """
        {
          "schemaVersion": 1,
          "deviceId": "mac-1",
          "companyId": "acme",
          "area": {"areaId": "finance", "name": "Finance"},
          "areas": [
            {"areaId": "finance", "name": "Finance", "declaredProcesses": [
              {"processId": "refund-handling", "name": "Refund handling"}]},
            {"areaId": "sales", "name": "Sales", "declaredProcesses": [
              {"processId": "quote", "name": "Quote", "futureField": true}]}
          ],
          "declaredProcesses": [
            {"processId": "refund-handling", "name": "Refund handling",
             "description": "Customer refunds"},
            {"processId": "invoice-approval", "name": "Invoice approval"}
          ],
          "person": {"personId": "per-1", "displayName": "Jana"},
          "bindingState": "confirmed",
          "assigned": [
            {"assignmentId": "asg-1", "areaId": "finance", "processId": "refund-handling",
             "processLabel": "Refund handling", "state": "open"}
          ],
          "minClientVersion": "0.27.0",
          "someFutureField": {"nested": [1, 2, 3]}
        }
        """

    private func signedRoute(
        ingestEndpoint: String = "https://jazz.example/api/archive-ingests"
    ) throws -> JazzArchiveUploadRouteBinding {
        try JazzArchiveUploadRouteBinding(
            ingestEndpoint: ingestEndpoint,
            stackURL: "https://connection.example.keboola.com",
            projectId: "123",
            tokenId: "456",
            scope: JazzArchiveUploadScope(
                companyId: "acme",
                areaId: "finance",
                deviceId: "mac-1"),
            signedAuthority: JazzArchiveSignedEnrollmentAuthority(
                issuer: "https://issuer.example",
                audience: "jazz-desktop",
                bundleId: "jdb_00000000000000000000000000000001",
                generation: 1,
                envelopeDigest: String(repeating: "c", count: 64)))
    }
}
