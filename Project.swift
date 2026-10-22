import ProjectDescription

let devExpEmbeddedSecretsSwiftFlags: SettingValue = "$(inherited) -D AGENTTY_BOOTSTRAP_SEED -D AGENTTY_EMBED_AI_KEYS"
let appGroupIdentifier = "$(AGENTTY_APP_GROUP)"
let projectMarketingVersion: SettingValue = "0.0.0"
let projectBuildNumber: SettingValue = "1"
let agenttySentryDSN = "$(AGENTTY_SENTRY_DSN)"
let appResources: ResourceFileElements = [
    .glob(
        pattern: "AgenTTY/Resources/**",
        excluding: [
            "AgenTTY/Resources/AgenTTYLocalSecrets.json",
            "AgenTTY/Resources/ghostty/**",
            "AgenTTY/Resources/notifications/**",
        ]
    ),
    .folderReference(path: "AgenTTY/Resources/ghostty"),
    .folderReference(path: "AgenTTY/Resources/notifications"),
]
let devExpAppResources: ResourceFileElements = [
    .glob(
        pattern: "AgenTTY/Resources/**",
        excluding: [
            "AgenTTY/Resources/ghostty/**",
            "AgenTTY/Resources/notifications/**",
        ]
    ),
    .folderReference(path: "AgenTTY/Resources/ghostty"),
    .folderReference(path: "AgenTTY/Resources/notifications"),
]
let mainNotificationServiceTargetName = "AgenTTY-iOS-NotificationService"
let devNotificationServiceTargetName = "AgenTTY-iOS-Dev-NotificationService"
let expNotificationServiceTargetName = "AgenTTY-iOS-Exp-NotificationService"
let iosTestSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_WARN_CONCURRENCY": "YES",
    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
    "SWIFT_REQUIRE_EXPLICIT_SENDABLE": "YES",
    "SWIFT_STRICT_LANGUAGE_FEATURES": "YES",
    "SWIFT_STRICT_MEMORY_SAFETY": "YES",
    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
    "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT": "YES",
    "SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES": "YES",
    "SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES": "YES",
    "SWIFT_UPCOMING_FEATURE_DISABLE_OUTWARD_ACTOR_INFERENCE": "YES",
    "SWIFT_UPCOMING_FEATURE_GLOBAL_ACTOR_ISOLATED_TYPES_USABILITY": "YES",
    "MARKETING_VERSION": projectMarketingVersion,
    "CURRENT_PROJECT_VERSION": projectBuildNumber,
    "GENERATE_INFOPLIST_FILE": "YES",
]

// Manual signing is pinned per channel where the extension ships or installs:
// the main NSE gets the App Store profile in Release, the dev NSE gets its
// development profile in Debug. The exp NSE is local-only and stays automatic.
func notificationServiceTarget(
    name: String,
    bundleId: String,
    displayName: String,
    releaseProfile: String? = nil,
    developmentProfile: String? = nil
) -> Target {
    var signingConfigurations: [Configuration] = []
    if let developmentProfile {
        signingConfigurations.append(.debug(name: .debug, settings: [
            "CODE_SIGN_STYLE": "$(AGENTTY_DEV_SIGN_STYLE)",
            "CODE_SIGN_IDENTITY": "Apple Development",
            "PROVISIONING_PROFILE_SPECIFIER": .string(developmentProfile),
        ]))
    }
    if let releaseProfile {
        signingConfigurations.append(.release(name: .release, settings: [
            "CODE_SIGN_STYLE": "$(AGENTTY_RELEASE_SIGN_STYLE)",
            "CODE_SIGN_IDENTITY": "Apple Distribution",
            "PROVISIONING_PROFILE_SPECIFIER": .string(releaseProfile),
        ]))
    }
    let base: SettingsDictionary = [
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "SWIFT_WARN_CONCURRENCY": "YES",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
        "SWIFT_REQUIRE_EXPLICIT_SENDABLE": "YES",
        "SWIFT_STRICT_LANGUAGE_FEATURES": "YES",
        "SWIFT_STRICT_MEMORY_SAFETY": "YES",
        "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
        "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT": "YES",
        "SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES": "YES",
        "SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES": "YES",
        "SWIFT_UPCOMING_FEATURE_DISABLE_OUTWARD_ACTOR_INFERENCE": "YES",
        "SWIFT_UPCOMING_FEATURE_GLOBAL_ACTOR_ISOLATED_TYPES_USABILITY": "YES",
        "APPLICATION_EXTENSION_API_ONLY": "YES",
        "CODE_SIGN_STYLE": "Automatic",

        "TARGETED_DEVICE_FAMILY": "1,2",
        "MARKETING_VERSION": projectMarketingVersion,
        "CURRENT_PROJECT_VERSION": projectBuildNumber,
        "INFOPLIST_KEY_CFBundleDisplayName": .string(displayName),
        "INFOPLIST_KEY_CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "INFOPLIST_KEY_CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    ]
    return .target(
        name: name,
        destinations: .iOS,
        product: .appExtension,
        bundleId: bundleId,
        deploymentTargets: .iOS("26.0"),
        infoPlist: .extendingDefault(with: [
            "CFBundleDisplayName": .string(displayName),
            "CFBundleShortVersionString": .string("$(MARKETING_VERSION)"),
            "CFBundleVersion": .string("$(CURRENT_PROJECT_VERSION)"),
            "NSExtension": .dictionary([
                "NSExtensionPointIdentifier": .string("com.apple.usernotifications.service"),
                "NSExtensionPrincipalClass": .string("$(PRODUCT_MODULE_NAME).AgenTTYNotificationServiceExtension"),
            ]),
        ]),
        buildableFolders: [
            "AgenTTY/Sources/NotificationsShared",
            "AgenTTY/Sources/NotificationServiceExtension",
        ],
        settings: signingConfigurations.isEmpty
            ? .settings(base: base, configurations: [.debug(name: .debug), .release(name: .release)])
            : .settings(base: base, configurations: signingConfigurations)
    )
}

let project = Project(
    name: "AgenTTY",
    packages: [
        .package(url: "https://github.com/apple/swift-nio.git", .exact("2.104.0")),
        .package(url: "https://github.com/emileberhard/swift-nio-ssh.git", .revision("ee3fd9f859d446c4f35ff768d9d79da864ae5e97")),
        .package(url: "https://github.com/apple/swift-crypto.git", .exact("4.5.2")),
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", .exact("9.9.0")),
        .package(url: "https://github.com/huggingface/AnyLanguageModel.git", .exact("1.0.0")),
        .package(url: "https://github.com/emileberhard/SpeechKit.git", .revision("d5e03d9701bb324fefc40edd42d0291ac2b618ab")),
    ],
    settings: .settings(configurations: [
        .debug(name: .debug, xcconfig: "Config/Defaults.xcconfig"),
        .release(name: .release, xcconfig: "Config/Defaults.xcconfig"),
    ]),
    targets: [
        .target(
            name: "AgenTTY-macOS",
            destinations: .macOS,
            product: .app,
            bundleId: "$(AGENTTY_BUNDLE_ID).macOS",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            resources: appResources,
            buildableFolders: [
                "AgenTTY/Sources/Common",
                "AgenTTY/Sources/NotificationsShared",
                "AgenTTY/Sources/macOS",
            ],
            dependencies: [
                .xcframework(path: "Vendor/GhosttyKit.xcframework"),
                .package(product: "NIOCore"),
                .package(product: "NIOPosix"),
                .package(product: "NIOSSH"),
                .package(product: "Crypto"),
                .package(product: "_CryptoExtras"),
                .package(product: "AnyLanguageModel"),
                .package(product: "SpeechKit"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.0",
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                    "SWIFT_WARN_CONCURRENCY": "YES",
                    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
                    "SWIFT_REQUIRE_EXPLICIT_SENDABLE": "YES",
                    "SWIFT_STRICT_LANGUAGE_FEATURES": "YES",
                    "SWIFT_STRICT_MEMORY_SAFETY": "YES",
                    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
                    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
                    "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT": "YES",
                    "SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES": "YES",
                    "SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES": "YES",
                    "SWIFT_UPCOMING_FEATURE_DISABLE_OUTWARD_ACTOR_INFERENCE": "YES",
                    "SWIFT_UPCOMING_FEATURE_GLOBAL_ACTOR_ISOLATED_TYPES_USABILITY": "YES",
                    "OTHER_LDFLAGS": "$(inherited) -lc++ -framework Carbon",
                ]
            )
        ),
        .target(
            name: "AgenTTY-iOS",
            destinations: .iOS,
            product: .app,
            bundleId: "$(AGENTTY_BUNDLE_ID)",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CADisableMinimumFrameDurationOnPhone": true,
                "CFBundleDisplayName": "AgenTTY",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "ITSAppUsesNonExemptEncryption": false,
                "NSCameraUsageDescription": "AgenTTY uses the camera to scan host pairing QR codes.",
                "NSMicrophoneUsageDescription": "AgenTTY uses the microphone for enhanced dictation and sends audio to AgenTTY's OpenAI transcription service.",
                "AGENTTY_SENTRY_DSN": .string(agenttySentryDSN),
                "AGENTTY_APP_GROUP": "$(AGENTTY_APP_GROUP)",
                "AGENTTY_CLOUDKIT_CONTAINER": "$(AGENTTY_CLOUDKIT_CONTAINER)",
                "AGENTTY_KEYCHAIN_NAMESPACE": "$(AGENTTY_KEYCHAIN_NAMESPACE)",
                "AGENTTY_UNLOCK_PRODUCT_ID": "$(AGENTTY_UNLOCK_PRODUCT_ID)",
                "AGENTTY_RELAY_URL": "$(AGENTTY_RELAY_URL)",
                "AGENTTY_ARTIFACT_URL": "$(AGENTTY_ARTIFACT_URL)",
                "AGENTTY_RELEASE_ARTIFACT_URL": "$(AGENTTY_RELEASE_ARTIFACT_URL)",
                "UIBackgroundModes": ["audio", "remote-notification"],
                "UILaunchScreen": [:],
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                "UISupportedInterfaceOrientations~ipad": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
            ]),
            resources: appResources,
            buildableFolders: [
                "AgenTTY/Sources/Common",
                "AgenTTY/Sources/NotificationsShared",
                "AgenTTY/Sources/iOS",
            ],
            entitlements: .dictionary([
                "aps-environment": .string("production"),
                "com.apple.developer.icloud-container-identifiers": .array([.string("$(AGENTTY_CLOUDKIT_CONTAINER)")]),
                "com.apple.developer.icloud-services": .array([.string("CloudKit")]),
                "com.apple.security.application-groups": .array([
                    .string(appGroupIdentifier),
                ]),
            ]),
            dependencies: [
                .xcframework(path: "Vendor/GhosttyKit.xcframework"),
                .package(product: "NIOCore"),
                .package(product: "NIOPosix"),
                .package(product: "NIOSSH"),
                .package(product: "Crypto"),
                .package(product: "_CryptoExtras"),
                .package(product: "Sentry"),
                .package(product: "AnyLanguageModel"),
                .package(product: "SpeechKit"),
                .package(product: "DictationLibrary"),
                .target(name: mainNotificationServiceTargetName),
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.0",
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                    "SWIFT_WARN_CONCURRENCY": "YES",
                    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
                    "SWIFT_REQUIRE_EXPLICIT_SENDABLE": "YES",
                    "SWIFT_STRICT_LANGUAGE_FEATURES": "YES",
                    "SWIFT_STRICT_MEMORY_SAFETY": "YES",
                    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
                    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
                    "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT": "YES",
                    "SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES": "YES",
                    "SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES": "YES",
                    "SWIFT_UPCOMING_FEATURE_DISABLE_OUTWARD_ACTOR_INFERENCE": "YES",
                    "SWIFT_UPCOMING_FEATURE_GLOBAL_ACTOR_ISOLATED_TYPES_USABILITY": "YES",
                    "OTHER_LDFLAGS": "$(inherited) -lc++",
                    "CODE_SIGN_STYLE": "Automatic",

                    "TARGETED_DEVICE_FAMILY": "1,2",
                    "MARKETING_VERSION": projectMarketingVersion,
                    "CURRENT_PROJECT_VERSION": projectBuildNumber,
                    "INFOPLIST_KEY_CFBundleShortVersionString": "$(MARKETING_VERSION)",
                    "INFOPLIST_KEY_CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                ],
                configurations: [
                    .debug(
                        name: .debug,
                        settings: [
                            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                            "INFOPLIST_KEY_CFBundleDisplayName": "AgenTTY",
                        ]
                    ),
                    .release(
                        name: .release,
                        settings: [
                            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                            "INFOPLIST_KEY_CFBundleDisplayName": "AgenTTY",
                            // Local maintainers can select pre-created profiles through Local.xcconfig.
                            // Hosted unsigned archives use automatic cloud export separately.
                            "CODE_SIGN_STYLE": "$(AGENTTY_RELEASE_SIGN_STYLE)",
                            "CODE_SIGN_IDENTITY": "Apple Distribution",
                            "PROVISIONING_PROFILE_SPECIFIER": "$(AGENTTY_RELEASE_APP_PROFILE)",
                        ]
                    ),
                ]
            )
        ),
        .target(
            name: "AgenTTY-iOS-Dev",
            destinations: .iOS,
            product: .app,
            bundleId: "$(AGENTTY_BUNDLE_ID).dev",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CADisableMinimumFrameDurationOnPhone": true,
                "CFBundleDisplayName": "AgenTTY DEV",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSCameraUsageDescription": "AgenTTY uses the camera to scan host pairing QR codes.",
                "NSMicrophoneUsageDescription": "AgenTTY uses the microphone for dictation and sends audio to the selected AI provider (Google Gemini, OpenAI, or ElevenLabs) for transcription.",
                "AGENTTY_SENTRY_DSN": .string(agenttySentryDSN),
                "AGENTTY_APP_GROUP": "$(AGENTTY_APP_GROUP)",
                "AGENTTY_CLOUDKIT_CONTAINER": "$(AGENTTY_CLOUDKIT_CONTAINER)",
                "AGENTTY_KEYCHAIN_NAMESPACE": "$(AGENTTY_KEYCHAIN_NAMESPACE)",
                "AGENTTY_UNLOCK_PRODUCT_ID": "$(AGENTTY_UNLOCK_PRODUCT_ID)",
                "AGENTTY_RELAY_URL": "$(AGENTTY_RELAY_URL)",
                "AGENTTY_ARTIFACT_URL": "$(AGENTTY_ARTIFACT_URL)",
                "AGENTTY_RELEASE_ARTIFACT_URL": "$(AGENTTY_RELEASE_ARTIFACT_URL)",
                "UIBackgroundModes": ["audio", "remote-notification"],
                "UILaunchScreen": [:],
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                "UISupportedInterfaceOrientations~ipad": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
            ]),
            resources: devExpAppResources,
            buildableFolders: [
                "AgenTTY/Sources/Common",
                "AgenTTY/Sources/NotificationsShared",
                "AgenTTY/Sources/iOS",
            ],
            entitlements: .dictionary([
                "aps-environment": .string("development"),
                "com.apple.developer.icloud-container-identifiers": .array([.string("$(AGENTTY_CLOUDKIT_CONTAINER)")]),
                "com.apple.developer.icloud-services": .array([.string("CloudKit")]),
                "com.apple.developer.icloud-container-environment": .string("Production"),
                "com.apple.security.application-groups": .array([
                    .string(appGroupIdentifier),
                ]),
            ]),
            dependencies: [
                .xcframework(path: "Vendor/GhosttyKit.xcframework"),
                .package(product: "NIOCore"),
                .package(product: "NIOPosix"),
                .package(product: "NIOSSH"),
                .package(product: "Crypto"),
                .package(product: "_CryptoExtras"),
                .package(product: "Sentry"),
                .package(product: "AnyLanguageModel"),
                .package(product: "SpeechKit"),
                .package(product: "DictationLibrary"),
                .target(name: devNotificationServiceTargetName),
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.0",
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                    "SWIFT_WARN_CONCURRENCY": "YES",
                    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
                    "SWIFT_REQUIRE_EXPLICIT_SENDABLE": "YES",
                    "SWIFT_STRICT_LANGUAGE_FEATURES": "YES",
                    "SWIFT_STRICT_MEMORY_SAFETY": "YES",
                    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
                    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
                    "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT": "YES",
                    "SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES": "YES",
                    "SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES": "YES",
                    "SWIFT_UPCOMING_FEATURE_DISABLE_OUTWARD_ACTOR_INFERENCE": "YES",
                    "SWIFT_UPCOMING_FEATURE_GLOBAL_ACTOR_ISOLATED_TYPES_USABILITY": "YES",
                    "OTHER_LDFLAGS": "$(inherited) -lc++",
                    "OTHER_SWIFT_FLAGS": devExpEmbeddedSecretsSwiftFlags,
                    "CODE_SIGN_STYLE": "Automatic",

                    "TARGETED_DEVICE_FAMILY": "1,2",
                    "MARKETING_VERSION": projectMarketingVersion,
                    "CURRENT_PROJECT_VERSION": projectBuildNumber,
                    "INFOPLIST_KEY_CFBundleShortVersionString": "$(MARKETING_VERSION)",
                    "INFOPLIST_KEY_CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                ],
                configurations: [
                    .debug(
                        name: .debug,
                        settings: [
                            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIconDev",
                            "INFOPLIST_KEY_CFBundleDisplayName": "AgenTTY DEV",
                            // Local iPhone/iPad install path: manual development
                            // signing against the canonical apple-signing keychain,
                            // profile installed by `just ios-build-install-dev`.
                            "CODE_SIGN_STYLE": "$(AGENTTY_DEV_SIGN_STYLE)",
                            "CODE_SIGN_IDENTITY": "Apple Development",
                            "PROVISIONING_PROFILE_SPECIFIER": "$(AGENTTY_DEV_APP_PROFILE)",
                        ]
                    ),
                    .release(
                        name: .release,
                        settings: [
                            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIconDev",
                            "INFOPLIST_KEY_CFBundleDisplayName": "AgenTTY DEV",
                        ]
                    ),
                ]
            )
        ),
        .target(
            name: "AgenTTY-iOS-Exp",
            destinations: .iOS,
            product: .app,
            bundleId: "$(AGENTTY_BUNDLE_ID).exp",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CADisableMinimumFrameDurationOnPhone": true,
                "CFBundleDisplayName": "AgenTTY EXP",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSCameraUsageDescription": "AgenTTY uses the camera to scan host pairing QR codes.",
                "NSMicrophoneUsageDescription": "AgenTTY uses the microphone for dictation and sends audio to the selected AI provider (Google Gemini, OpenAI, or ElevenLabs) for transcription.",
                "AGENTTY_SENTRY_DSN": .string(agenttySentryDSN),
                "AGENTTY_APP_GROUP": "$(AGENTTY_APP_GROUP)",
                "AGENTTY_CLOUDKIT_CONTAINER": "$(AGENTTY_CLOUDKIT_CONTAINER)",
                "AGENTTY_KEYCHAIN_NAMESPACE": "$(AGENTTY_KEYCHAIN_NAMESPACE)",
                "AGENTTY_UNLOCK_PRODUCT_ID": "$(AGENTTY_UNLOCK_PRODUCT_ID)",
                "AGENTTY_RELAY_URL": "$(AGENTTY_RELAY_URL)",
                "AGENTTY_ARTIFACT_URL": "$(AGENTTY_ARTIFACT_URL)",
                "AGENTTY_RELEASE_ARTIFACT_URL": "$(AGENTTY_RELEASE_ARTIFACT_URL)",
                "UIBackgroundModes": ["audio", "remote-notification"],
                "UILaunchScreen": [:],
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                "UISupportedInterfaceOrientations~ipad": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
            ]),
            resources: devExpAppResources,
            buildableFolders: [
                "AgenTTY/Sources/Common",
                "AgenTTY/Sources/NotificationsShared",
                "AgenTTY/Sources/iOS",
            ],
            entitlements: .dictionary([
                "aps-environment": .string("development"),
                "com.apple.developer.icloud-container-identifiers": .array([.string("$(AGENTTY_CLOUDKIT_CONTAINER)")]),
                "com.apple.developer.icloud-services": .array([.string("CloudKit")]),
                "com.apple.developer.icloud-container-environment": .string("Production"),
                "com.apple.security.application-groups": .array([
                    .string(appGroupIdentifier),
                ]),
            ]),
            dependencies: [
                .xcframework(path: "Vendor/GhosttyKit.xcframework"),
                .package(product: "NIOCore"),
                .package(product: "NIOPosix"),
                .package(product: "NIOSSH"),
                .package(product: "Crypto"),
                .package(product: "_CryptoExtras"),
                .package(product: "Sentry"),
                .package(product: "AnyLanguageModel"),
                .package(product: "SpeechKit"),
                .package(product: "DictationLibrary"),
                .target(name: expNotificationServiceTargetName),
            ],
            settings: .settings(
                base: [
                    "SWIFT_VERSION": "6.0",
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                    "SWIFT_WARN_CONCURRENCY": "YES",
                    "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
                    "SWIFT_REQUIRE_EXPLICIT_SENDABLE": "YES",
                    "SWIFT_STRICT_LANGUAGE_FEATURES": "YES",
                    "SWIFT_STRICT_MEMORY_SAFETY": "YES",
                    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
                    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
                    "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT": "YES",
                    "SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES": "YES",
                    "SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES": "YES",
                    "SWIFT_UPCOMING_FEATURE_DISABLE_OUTWARD_ACTOR_INFERENCE": "YES",
                    "SWIFT_UPCOMING_FEATURE_GLOBAL_ACTOR_ISOLATED_TYPES_USABILITY": "YES",
                    "OTHER_LDFLAGS": "$(inherited) -lc++",
                    "OTHER_SWIFT_FLAGS": devExpEmbeddedSecretsSwiftFlags,
                    "CODE_SIGN_STYLE": "Automatic",

                    "TARGETED_DEVICE_FAMILY": "1,2",
                    "MARKETING_VERSION": projectMarketingVersion,
                    "CURRENT_PROJECT_VERSION": projectBuildNumber,
                    "INFOPLIST_KEY_CFBundleShortVersionString": "$(MARKETING_VERSION)",
                    "INFOPLIST_KEY_CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                ],
                configurations: [
                    .debug(
                        name: .debug,
                        settings: [
                            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIconDev",
                            "INFOPLIST_KEY_CFBundleDisplayName": "AgenTTY EXP",
                        ]
                    ),
                    .release(
                        name: .release,
                        settings: [
                            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIconDev",
                            "INFOPLIST_KEY_CFBundleDisplayName": "AgenTTY EXP",
                        ]
                    ),
                ]
            )
        ),
        .target(
            name: "AgenTTY-iOS-Tests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "$(AGENTTY_BUNDLE_ID).tests",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .default,
            sources: ["AgenTTY/Tests/**"],
            dependencies: [
                // NIOEmbedded is test-only (EmbeddedEventLoop for the auth-ladder
                // tests); the other NIO/Crypto modules come through the hosted app
                // target. Re-listing app-linked products here makes Xcode produce
                // the dynamic Crypto.framework twice ("Multiple commands produce").
                .target(name: "AgenTTY-iOS"),
                .package(product: "NIOEmbedded"),
            ],
            settings: .settings(base: iosTestSettings, configurations: [.debug(name: .debug), .release(name: .release)])
        ),
        .target(
            name: "AgenTTY-iOS-LLM-IntegrationTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "$(AGENTTY_BUNDLE_ID).llmIntegrationTests",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .default,
            sources: ["AgenTTY/IntegrationTests/**"],
            resources: ["AgenTTY/IntegrationTests/Fixtures/**"],
            dependencies: [
                .target(name: "AgenTTY-iOS-Dev"),
            ],
            settings: .settings(base: iosTestSettings, configurations: [.debug(name: .debug), .release(name: .release)])
        ),
        notificationServiceTarget(
            name: mainNotificationServiceTargetName,
            bundleId: "$(AGENTTY_BUNDLE_ID).NotificationService",
            displayName: "AgenTTY Notifications",
            releaseProfile: "$(AGENTTY_RELEASE_EXTENSION_PROFILE)"
        ),
        notificationServiceTarget(
            name: devNotificationServiceTargetName,
            bundleId: "$(AGENTTY_BUNDLE_ID).dev.NotificationService",
            displayName: "AgenTTY DEV Notifications",
            developmentProfile: "$(AGENTTY_DEV_EXTENSION_PROFILE)"
        ),
        notificationServiceTarget(
            name: expNotificationServiceTargetName,
            bundleId: "$(AGENTTY_BUNDLE_ID).exp.NotificationService",
            displayName: "AgenTTY EXP Notifications"
        ),
    ]
)
