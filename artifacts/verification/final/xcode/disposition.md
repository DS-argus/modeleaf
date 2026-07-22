# Xcode validation disposition

- Xcode: 26.6 (17F113)
- Generated project validation: passed.
- xcodebuild -version: exit 0.
- xcodebuild -checkFirstLaunchStatus: exit 69.
- Xcode project resolve/build/build-for-testing/test/analyze: exit 70 before project loading because IDESimulatorFoundation cannot load the host's missing /Library/Developer/PrivateFrameworks/CoreSimulator.framework.
- Result bundle created: false.
- First-launch repair: not attempted because it mutates administrator-gated host state and sudo -n requires a password.
- Classification: external Xcode installation blocker, not a project-source failure.
- Consequence: XCUITest GUI execution, Xcode build, and Xcode analyze remain unexecuted on this host; SwiftPM builds/tests, warnings-as-errors, direct UI-source typecheck, app launch smoke, and visual snapshot generation provide the available local evidence.
