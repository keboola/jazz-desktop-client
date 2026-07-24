import Foundation

/// Stable, non-secret authority that owns one Capture Coach delivery partition. Credential and
/// enrollment audit rotation fields are deliberately excluded so a rotated token can drain the
/// same queue, while every field that could redirect or broaden delivery remains pinned.
public struct CaptureCoachLiveRouteAuthority: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var ingestEndpoint: String
  public var ingestOrigin: String
  public var stackURL: String
  public var projectId: String
  public var companyId: String
  public var areaId: String
  public var deviceId: String
  public var issuer: String
  public var audience: String

  public init(routeBinding: JazzArchiveUploadRouteBinding) throws {
    guard routeBinding.hasSignedAuthority, let signed = routeBinding.signedAuthority else {
      throw CaptureCoachLiveSpoolError.invalidRoot
    }
    schemaVersion = 1
    ingestEndpoint = routeBinding.ingestEndpoint
    ingestOrigin = routeBinding.ingestOrigin
    stackURL = routeBinding.stackURL
    projectId = routeBinding.projectId
    companyId = routeBinding.scope.companyId
    areaId = routeBinding.scope.areaId
    deviceId = routeBinding.scope.deviceId
    issuer = signed.issuer
    audience = signed.audience
    try validate()
  }

  public func partitionId() throws -> String {
    "route-\(JazzArchiveDigest.sha256Hex(try JazzArchiveCanonicalJSON.encode(self)))"
  }

  public func validate() throws {
    guard schemaVersion == 1,
      !ingestEndpoint.isEmpty,
      !ingestOrigin.isEmpty,
      !stackURL.isEmpty,
      !projectId.isEmpty,
      !companyId.isEmpty,
      !areaId.isEmpty,
      !deviceId.isEmpty,
      !issuer.isEmpty,
      !audience.isEmpty
    else { throw CaptureCoachLiveSpoolError.invalidRoot }
  }
}

public struct CaptureCoachLiveBoundRoutePartition: Equatable, Sendable {
  public var root: URL
  public var authority: CaptureCoachLiveRouteAuthority

  public init(root: URL, authority: CaptureCoachLiveRouteAuthority) {
    self.root = root
    self.authority = authority
  }
}

/// Binds exact-byte queues to one immutable signed delivery authority. A route switch creates a
/// different directory, so a stale item can never block the current enrollment's head of line.
/// Every accepted route snapshot is retained as canonical non-secret metadata for audit/recovery.
public enum CaptureCoachLiveRoutePartition {
  private static let authorityFileName = "authority.json"
  private static let routeSnapshotsDirectoryName = "route-snapshots"

  public static func bind(
    baseRoot: URL,
    routeBinding: JazzArchiveUploadRouteBinding,
    durability: JazzArchiveFilesystemDurability,
    fileManager: FileManager = .default
  ) throws -> CaptureCoachLiveBoundRoutePartition {
    guard baseRoot.isFileURL else { throw CaptureCoachLiveSpoolError.invalidRoot }
    let authority = try CaptureCoachLiveRouteAuthority(routeBinding: routeBinding)
    let partitions = baseRoot.appendingPathComponent("partitions", isDirectory: true)
    let root = partitions.appendingPathComponent(
      try authority.partitionId(), isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let authorityBytes = try JazzArchiveCanonicalJSON.encode(authority)
    try publishOrVerify(
      authorityBytes,
      at: root.appendingPathComponent(authorityFileName),
      root: root,
      durability: durability,
      fileManager: fileManager)

    let snapshots = root.appendingPathComponent(
      routeSnapshotsDirectoryName, isDirectory: true)
    try fileManager.createDirectory(at: snapshots, withIntermediateDirectories: true)
    let routeSnapshot = try CaptureCoachLiveRouteSnapshot(routeBinding: routeBinding)
    let routeBytes = try JazzArchiveCanonicalJSON.encode(routeSnapshot)
    let routeDigest = JazzArchiveDigest.sha256Hex(routeBytes)
    try publishOrVerify(
      routeBytes,
      at: snapshots.appendingPathComponent("\(routeDigest).json"),
      root: root,
      durability: durability,
      fileManager: fileManager)
    try durability.synchronizeDirectory(snapshots)
    try durability.synchronizeDirectory(root)
    try durability.synchronizeDirectory(partitions)
    try durability.synchronizeDirectory(baseRoot)
    return CaptureCoachLiveBoundRoutePartition(root: root, authority: authority)
  }

  private static func publishOrVerify(
    _ data: Data,
    at destination: URL,
    root: URL,
    durability: JazzArchiveFilesystemDurability,
    fileManager: FileManager
  ) throws {
    if fileManager.fileExists(atPath: destination.path) {
      guard try Data(contentsOf: destination) == data else {
        throw CaptureCoachLiveSpoolError.identifierCollision(
          destination.lastPathComponent)
      }
      try durability.synchronizeRegularFile(
        destination, permissions: Int16(0o600))
      try durability.synchronizeDirectory(destination.deletingLastPathComponent())
      try durability.synchronizeDirectory(root)
      return
    }
    let temporary = root.appendingPathComponent(
      ".route-\(Identifiers.newUUIDv7().uuidString.lowercased())")
    var keepTemporary = true
    defer { if keepTemporary { try? fileManager.removeItem(at: temporary) } }
    guard
      fileManager.createFile(
        atPath: temporary.path,
        contents: data,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
    else { throw CaptureCoachLiveSpoolError.invalidRoot }
    try durability.synchronizeRegularFile(
      temporary, permissions: Int16(0o600))
    do {
      try fileManager.moveItem(at: temporary, to: destination)
      keepTemporary = false
      try durability.synchronizeRegularFile(
        destination, permissions: Int16(0o600))
      try durability.synchronizeDirectory(destination.deletingLastPathComponent())
      try durability.synchronizeDirectory(root)
    } catch {
      if fileManager.fileExists(atPath: destination.path),
        try Data(contentsOf: destination) == data
      {
        try durability.synchronizeRegularFile(
          destination, permissions: Int16(0o600))
        try durability.synchronizeDirectory(destination.deletingLastPathComponent())
        return
      }
      throw error
    }
  }
}

/// Audit snapshot for one accepted enrollment rotation. It deliberately excludes both credential
/// bytes and token identifiers; the route, signer, scope, and signed-envelope evidence are enough
/// to explain which authority owned the durable queue.
public struct CaptureCoachLiveRouteSnapshot: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var authority: CaptureCoachLiveRouteAuthority
  public var bundleId: String
  public var generation: Int
  public var envelopeDigest: String

  public init(routeBinding: JazzArchiveUploadRouteBinding) throws {
    guard routeBinding.hasSignedAuthority, let signed = routeBinding.signedAuthority else {
      throw CaptureCoachLiveSpoolError.invalidRoot
    }
    schemaVersion = 1
    authority = try CaptureCoachLiveRouteAuthority(routeBinding: routeBinding)
    bundleId = signed.bundleId
    generation = signed.generation
    envelopeDigest = signed.envelopeDigest
  }
}
