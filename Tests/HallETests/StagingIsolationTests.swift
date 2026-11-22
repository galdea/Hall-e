import Foundation
import Testing
@testable import HallE

@Suite("Staging isolation")
struct StagingIsolationTests {
    @Test func onlyTheStagingBundleIdentifierSelectsStaging() {
        #expect(AppPaths.isStaging(bundleIdentifier: "cl.gabriel.hall-e.staging"))
        #expect(!AppPaths.isStaging(bundleIdentifier: "cl.gabriel.hall-e"))
        #expect(!AppPaths.isStaging(bundleIdentifier: "cl.gabriel.hall-e.staging.extra"))
        #expect(!AppPaths.isStaging(bundleIdentifier: "CL.GABRIEL.HALL-E.STAGING"))
        #expect(!AppPaths.isStaging(bundleIdentifier: nil))
        // The test runner is never a staging bundle, so the live values are production's.
        #expect(!AppPaths.isStaging)
        #expect(AppPaths.bundleID == AppPaths.productionBundleID)
    }

    @Test func stagingUsesItsOwnApplicationSupportDirectoryAndKeychainService() {
        let base = URL(fileURLWithPath: "/tmp/halle-staging-isolation-fixture", isDirectory: true)
        let production = AppPaths.appSupportDirectory(base: base, isStaging: false)
        let staging = AppPaths.appSupportDirectory(base: base, isStaging: true)
        #expect(production.lastPathComponent == "Hall-e")
        #expect(staging.lastPathComponent == "Hall-e Staging")
        #expect(production != staging)
        #expect(production.deletingLastPathComponent().standardizedFileURL == base.standardizedFileURL)
        #expect(staging.deletingLastPathComponent().standardizedFileURL == base.standardizedFileURL)
        // Neither directory contains the other, so no file can be shared by path prefix.
        #expect(!staging.path.hasPrefix(production.path + "/"))
        #expect(!production.path.hasPrefix(staging.path + "/"))

        #expect(KeychainStore.service(isStaging: false) == "cl.gabriel.hall-e")
        #expect(KeychainStore.service(isStaging: true) == "cl.gabriel.hall-e.staging")
        #expect(KeychainStore.service(isStaging: true) != KeychainStore.service(isStaging: false))
        #expect(KeychainStore.service == KeychainStore.service(isStaging: AppPaths.isStaging))
        #expect(AppPaths.bundleID(isStaging: true) == AppPaths.stagingBundleID)
    }

    @Test func stagingBuildsCannotReachTheProductionPairingCoordinator() {
        #expect(!DistributionCapabilities.supportsSharedMeetingCoordinator(isStaging: true))
        #expect(DistributionCapabilities.supportsSharedMeetingCoordinator(isStaging: false))
        #expect(DistributionCapabilities.supportsSharedMeetingCoordinator ==
                DistributionCapabilities.supportsSharedMeetingCoordinator(isStaging: AppPaths.isStaging))
        #expect(!DistributionCapabilities.sharedMeetingsUnavailableExplanation.isEmpty)
    }
}
