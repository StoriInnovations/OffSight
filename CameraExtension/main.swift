import CoreMediaIO
import Foundation
import OffSightCore
import os

Logger(subsystem: OffSightConstants.logSubsystem, category: "provider")
    .info("OffSight Camera extension starting (build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?", privacy: .public))")

let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
